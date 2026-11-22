import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../polar/models.dart';
import '../polar/packed_recording.dart';
import '../polar/polar_bridge.dart';
import '../polar/polar_errors.dart';
import 'app_settings.dart';
import 'device_controller.dart';
import 'features.dart';
import 'live_hr.dart';
import 'live_ppi.dart';

enum SyncPhase {
  idle,
  waitingForDevice,
  connecting,
  settingTime,
  stoppingRecordings,
  listing,
  fetching,
  storing,
  restartingRecordings,
  done,
  error,
}

/// What the app knows about the recordings on the sensor. It only learns
/// this during a sync, so every state carries the time it was established.
enum RecordingState {
  /// Never confirmed (no sync yet on this phone).
  unknown,

  /// A sync has stopped the recordings to fetch them; nothing is recorded.
  paused,

  /// The sensor reported every wanted recording as running.
  recording,

  /// After a sync the sensor did not report every wanted recording, or the
  /// sync broke off while they were stopped.
  failed,
}

/// Keeps the sensor recording and the phone's database in step without a
/// standing connection: every trigger connects, syncs and disconnects, and
/// the phone rests in between.
///
/// Triggers: the schedule (Kotlin alarm → `scheduledSync` event), the app
/// starting or coming to the foreground, the user's "Sync now", and, if
/// enabled, the sensor appearing (Companion Device Manager event through the
/// SDK). One run at a time; a trigger during a run queues exactly one more.
///
/// A *live session* ([startLive]) is the one way to stay connected: it
/// streams HR (and PP intervals, see [LivePpiService]) to the dashboard until
/// the user stops it or the app leaves the foreground; it ends with a sync.
///
/// Each run: set the sensor clock → stop running offline recordings → list →
/// fetch each recording (packed) → store → delete from the sensor → make sure
/// the system-start trigger and the configured recordings are active →
/// retention.
class SyncService extends ChangeNotifier {
  SyncService(
    this.bridge,
    this.dc,
    this.repo,
    this.settings,
    this.livePpi,
    this.liveHr,
  ) {
    _events = bridge.events.listen(_onEvent);
    dc.addListener(_onDeviceChanged);
    settings.addListener(_onSettings);
  }

  final PolarBridge bridge;
  final DeviceController dc;
  final Repository repo;
  final AppSettings settings;

  /// Owns PPI while the app is open: the sync must not arm the sensor's PPI
  /// recording then, and hands over to it after each run.
  final LivePpiService livePpi;
  final LiveHrService liveHr;
  late final StreamSubscription<PolarEvent> _events;

  SyncPhase phase = SyncPhase.idle;
  String detail = '';
  int? progressPercent;
  DateTime? lastSyncAt;

  /// Bumped whenever stored data changed: after a sync, a live flush, a
  /// rebuild or a delete. Viewers key their queries on it.
  int dataVersion = 0;

  /// Called once the sensor is done with: after the disconnect that ends a
  /// sync (or a connect attempt that came to nothing) has completed, and
  /// before the foreground service is released, so the work survives in the
  /// background. The app controller hangs the online upload on it; this
  /// service knows nothing about accounts or the network and keeps working
  /// without either. It waits for the hook at most [afterDeviceLimit], and a
  /// new sync trigger never waits for it at all.
  Future<void> Function()? afterDevice;

  /// How long the foreground service is held for [afterDevice].
  static const afterDeviceLimit = Duration(minutes: 3);

  /// [afterDevice] is running; the idle fallback must not release the
  /// service under it.
  bool _finishing = false;

  /// Nothing is being said to the sensor and nothing is about to be.
  bool get deviceIdle =>
      !_running &&
      !_syncOnReady &&
      dc.connection == PolarConnectionState.disconnected;

  /// Tells viewers that stored data changed outside a sync.
  void dataChanged() {
    dataVersion++;
    notifyListeners();
  }

  /// Whether the sensor is recording, as far as the last sync could tell
  /// (kept in the settings table, so it survives the process).
  RecordingState recording = RecordingState.unknown;

  /// When [recording] was established.
  DateTime? recordingAt;

  /// The types the sensor reported as recording at [recordingAt].
  Set<PolarDataType> recordingTypes = {};

  /// Why not everything is recording ([RecordingState.failed]).
  String? recordingProblem;

  /// The sensor writes 0 as heart rate for its first 21 s of a recording, so
  /// a confirmed recording counts as started only this long after
  /// [recordingAt] (the card stays amber until then).
  static const recordingSettle = Duration(seconds: 20);

  static const _recordingKey = 'recording_status';

  Future<void> loadRecordingStatus() async {
    final raw = await repo.getSetting(_recordingKey);
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      recording = RecordingState.values.byName(m['state'] as String);
      recordingAt = DateTime.fromMillisecondsSinceEpoch(m['at'] as int);
      recordingTypes = {
        for (final t in m['types'] as List) PolarDataType.fromWire(t as String),
      };
      recordingProblem = m['problem'] as String?;
      // The process died between stopping and restarting the recordings.
      if (recording == RecordingState.paused) {
        recording = RecordingState.failed;
        recordingProblem = _interruptedLast;
      }
      _restartOwed =
          recording == RecordingState.failed &&
          (recordingProblem == _interrupted ||
              recordingProblem == _interruptedLast);
    } catch (_) {
      recording = RecordingState.unknown;
    }
    notifyListeners();
  }

  Future<void> _setRecording(
    RecordingState state, {
    Set<PolarDataType> types = const {},
    String? problem,
  }) async {
    recording = state;
    recordingAt = DateTime.now();
    recordingTypes = types;
    recordingProblem = problem;
    notifyListeners();
    await repo.setSetting(
      _recordingKey,
      jsonEncode({
        'state': state.name,
        'at': recordingAt!.millisecondsSinceEpoch,
        'types': [for (final t in types) t.wire],
        'problem': problem,
      }),
    );
  }

  String? lastError;
  DiskSpace? diskSpace;
  int lastRunRecordings = 0;
  int lastRunSamples = 0;

  bool _running = false;
  bool _queued = false;
  bool _syncOnReady = false;
  Timer? _idle;
  Timer? _connectTimeout;
  int? _scheduledHours;

  /// The user asked for live data; the connection stays up while true.
  bool liveRequested = false;

  /// What the live session streams: HR on the Heart rate graph, PP intervals
  /// on HRV. Follows the selected graph. Movement cannot be streamed: the
  /// Verity Sense (FW 3.0.16) reboots as soon as an online ACC stream starts
  /// while it records offline, so Live is greyed out on that graph.
  PolarDataType liveType = PolarDataType.hr;

  /// The types a live session can stream.
  static const liveTypes = {PolarDataType.hr, PolarDataType.ppi};

  static const _liveNeeded = {
    'FEATURE_HR',
    'FEATURE_POLAR_ONLINE_STREAMING',
    'FEATURE_POLAR_OFFLINE_RECORDING',
  };
  bool _liveStarting = false;

  /// [_ensureLiveStreams] ran for this connection; it runs once per
  /// connection, type switch and sync, never from a stream's own events
  /// (logging notifies the device controller, which would loop back here).
  bool _liveEnsured = false;

  /// Give up on a connect attempt after this: the sensor is off or away.
  static const connectTimeout = Duration(seconds: 90);

  /// While the sensor is known not to record what it should ([_restartOwed]),
  /// the sync alarm is brought forward instead of waiting for the schedule,
  /// which can be hours away: after these delays, one after the other. Every
  /// failed attempt (also a sensor that is not found) takes the next one; when
  /// they are used up the schedule takes over and starts the series again.
  static const retryDelays = [
    Duration(minutes: 1),
    Duration(minutes: 1),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
  ];

  /// The sensor was left not recording and a sync has to put that right: a
  /// sync broke off between stop and start, or the sensor did not start a
  /// type. Not set for a sensor in the charger (it cannot record there and
  /// starts by itself when taken out).
  bool _restartOwed = false;

  /// Retries armed in the current series.
  int _retries = 0;

  /// The sync alarm stands at a retry delay instead of the schedule.
  bool _retryArmed = false;

  static const _interrupted =
      'The sync was interrupted before recording restarted.';
  static const _interruptedLast = 'The last sync was interrupted.';

  Future<void> _armRetry() async {
    if (_retries >= retryDelays.length) {
      _log(
        'warn',
        'sensor still not recording after ${retryDelays.length} retries; '
            'waiting for the next sync',
      );
      // The app has done what it can; the wearer has to know.
      try {
        await bridge.alert(
          'Sensor is not recording',
          '${recordingProblem ?? 'Recording could not be restarted.'} '
              'Open heild with the sensor nearby.',
        );
      } catch (e) {
        _log('warn', 'alert not shown: $e');
      }
      return;
    }
    final delay = retryDelays[_retries++];
    try {
      await bridge.scheduleSyncIn(delay.inSeconds);
      _retryArmed = true;
      _log(
        'info',
        'sensor not recording: retry $_retries of ${retryDelays.length} '
            'in ${delay.inMinutes} min',
      );
    } catch (e) {
      _log('warn', 'retry not armed: $e');
    }
  }

  /// A sync completed: the alarm goes back to the schedule.
  Future<void> _clearRetry() async {
    _retries = 0;
    if (!_retryArmed) return;
    _retryArmed = false;
    try {
      await bridge.scheduleSync(settings.syncEveryHours);
    } catch (e) {
      _log('warn', 'schedule not restored: $e');
    }
  }

  /// Opening the app syncs when the last sync is older than this.
  static const staleAfter = Duration(minutes: 30);

  static const _needed = {
    'FEATURE_POLAR_OFFLINE_RECORDING',
    'FEATURE_POLAR_FILE_TRANSFER',
    'FEATURE_POLAR_DEVICE_TIME_SETUP',
  };

  bool get isRunning => _running;
  bool get isLive => liveRequested;

  /// Arms (or cancels) the Kotlin alarm to match the setting.
  Future<void> applySchedule() async {
    final h = settings.syncEveryHours;
    if (h == _scheduledHours) return;
    _scheduledHours = h;
    await bridge.scheduleSync(h);
    _log('info', h == 0 ? 'scheduled sync off' : 'scheduled sync every $h h');
  }

  void _onSettings() => unawaited(applySchedule());

  /// App lifecycle: a live session ends when the app leaves the foreground;
  /// opening the app syncs if the data is stale.
  void onForeground(bool foreground) {
    if (!foreground) {
      if (liveRequested) unawaited(stopLive(reason: 'app in background'));
      return;
    }
    if (!settings.isPaired || _running || dc.isConnected) return;
    if (dc.connection == PolarConnectionState.connecting) return;
    final last = lastSyncAt;
    if (last == null || DateTime.now().difference(last) > staleAfter) {
      unawaited(connectAndSync(reason: 'app opened'));
    }
  }

  // ---- triggers -------------------------------------------------------------

  void _onEvent(PolarEvent e) {
    switch (e.type) {
      case 'companionDeviceAppeared':
        // Presence is not a trigger any more and is switched off after every
        // connection (stopPresence), so this arrives only while connecting.
        // The presence service started the foreground service; hand it back
        // when no sync wants it.
        if (!dc.isConnected && !_running) unawaited(bridge.serviceIdle());
      case 'scheduledSync':
        // Kotlin has put the alarm back on the schedule by now.
        final retry = _retryArmed;
        _retryArmed = false;
        if (!retry) _retries = 0; // the schedule starts a new series
        _log('info', retry ? 'retrying the sync' : 'scheduled sync');
        unawaited(connectAndSync(reason: retry ? 'retry' : 'scheduled'));
    }
  }

  void _onDeviceChanged() {
    if (dc.isConnected) {
      _idle?.cancel();
      _connectTimeout?.cancel();
      if (_syncOnReady && dc.featuresReady.containsAll(_needed)) {
        _syncOnReady = false;
        unawaited(syncNow(reason: 'connected'));
      }
      if (liveRequested &&
          !_running &&
          !_liveEnsured &&
          dc.featuresReady.containsAll(_liveNeeded)) {
        unawaited(_ensureLiveStreams());
      }
    } else if (dc.connection == PolarConnectionState.disconnected) {
      _liveEnsured = false;
      if (_running) {
        // The run will fail on its next call and report it.
      } else {
        _scheduleIdleCheck();
      }
      notifyListeners();
    }
  }

  void _armConnectTimeout() {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(connectTimeout, () async {
      if (dc.isConnected || _running) return;
      _syncOnReady = false;
      if (await _bluetoothOff()) {
        _log('warn', 'Bluetooth was switched off while connecting');
        _setPhase(SyncPhase.error, bluetoothOffText);
      } else {
        _log('warn', 'sensor not found within ${connectTimeout.inSeconds} s');
        _setPhase(SyncPhase.error, 'Sensor not in range');
      }
      if (liveRequested) {
        liveRequested = false;
        notifyListeners();
      }
      if (_restartOwed) await _armRetry();
      await _rest();
    });
  }

  static const bluetoothOffText = 'Bluetooth is off. Switch it on to sync.';

  /// The phone's Bluetooth is switched off. A failed question counts as on,
  /// so the connect attempt still decides.
  Future<bool> _bluetoothOff() async {
    try {
      return !await bridge.bluetoothEnabled();
    } catch (_) {
      return false;
    }
  }

  /// Connects to the paired sensor (or [deviceId]) and syncs once ready.
  Future<void> connectAndSync({String? deviceId, String reason = ''}) async {
    final id = deviceId ?? settings.pairedDeviceId;
    if (id == null) {
      _setPhase(SyncPhase.error, 'No sensor paired');
      return;
    }
    if (!dc.isConnected && await _bluetoothOff()) {
      // Say so at once instead of scanning for [connectTimeout] and
      // reporting a sensor that is "not in range".
      _log('warn', 'Bluetooth is off${reason.isEmpty ? '' : ' ($reason)'}');
      _syncOnReady = false;
      _setPhase(SyncPhase.error, bluetoothOffText);
      if (liveRequested) {
        liveRequested = false;
        notifyListeners();
      }
      if (_restartOwed) await _armRetry();
      await _rest();
      return;
    }
    _idle?.cancel();
    await bridge.serviceStart();
    if (dc.isConnected && dc.deviceId == id) {
      await syncNow(reason: reason);
      return;
    }
    _syncOnReady = true;
    if (dc.connection == PolarConnectionState.connecting) return;
    await _connect(id, reason);
  }

  Future<void> _connect(String id, String reason) async {
    _setPhase(
      SyncPhase.connecting,
      'Connecting to ${settings.pairedName ?? id}',
    );
    _log('info', 'connecting ($reason)');
    await bridge.setAutomaticReconnection(liveRequested);
    try {
      await dc.connect(id);
      _armConnectTimeout();
    } on PolarException catch (e) {
      _syncOnReady = false;
      _setPhase(SyncPhase.error, 'Connect failed: $e');
      _log('error', 'connect failed: $e');
      if (_restartOwed) await _armRetry();
      await _rest();
    }
  }

  // ---- live session ---------------------------------------------------------

  /// Connects (if needed) and streams [type] to the Graphs page until
  /// [stopLive]. While live, [setLiveType] switches the stream.
  Future<void> startLive(PolarDataType type) async {
    final id = settings.pairedDeviceId;
    if (!liveEnabled) return;
    if (id == null || liveRequested || !liveTypes.contains(type)) return;
    liveRequested = true;
    liveType = type;
    notifyListeners();
    _log('info', 'live started (${type.label})');
    _idle?.cancel();
    await bridge.serviceStart();
    if (dc.isConnected && dc.deviceId == id) {
      if (!_running) await _ensureLiveStreams();
      return;
    }
    if (dc.connection == PolarConnectionState.connecting) return;
    await _connect(id, 'live');
  }

  /// Switches a running live session to [type] (starts one otherwise).
  Future<void> setLiveType(PolarDataType type) async {
    if (!liveRequested) return startLive(type);
    if (type == liveType || !liveTypes.contains(type)) return;
    liveType = type;
    notifyListeners();
    _log('info', 'live switched to ${type.label}');
    if (!_running && dc.isConnected) await _ensureLiveStreams();
  }

  /// Starts the stream of [liveType] and stops the others.
  Future<void> _ensureLiveStreams() async {
    if (_liveStarting || !liveRequested || !dc.isConnected) return;
    _liveStarting = true;
    _liveEnsured = true;
    try {
      final hr = liveType == PolarDataType.hr;
      if (hr && !dc.streams.containsKey(PolarDataType.hr)) {
        await dc.startStream(PolarDataType.hr);
      } else if (!hr && dc.streams.containsKey(PolarDataType.hr)) {
        await dc.stopStream(PolarDataType.hr);
      }
      unawaited(
        bridge.serviceNotification(
          'Live · ${settings.pairedName ?? dc.deviceId}',
          liveType == PolarDataType.ppi
              ? 'Streaming pulse intervals'
              : 'Streaming heart rate',
        ),
      );
    } catch (e) {
      _log('warn', 'live HR: $e');
    } finally {
      _liveStarting = false;
    }
    _log('info', 'live ${liveType.label} streaming');
    // The live connect leaves the phase at "connecting"; no sync follows.
    if (phase == SyncPhase.connecting) _setPhase(SyncPhase.idle, '');
    // Hands the PPI recording back to the sensor when not wanted.
    await livePpi.reconcile();
  }

  /// Ends the live session: stops the streams, syncs so the graphs are
  /// complete, and disconnects.
  Future<void> stopLive({String reason = 'stopped'}) async {
    if (!liveRequested) return;
    liveRequested = false;
    notifyListeners();
    _log('info', 'live ended ($reason)');
    if (dc.streams.containsKey(PolarDataType.hr)) {
      try {
        await dc.stopStream(PolarDataType.hr);
      } catch (e) {
        _log('warn', 'stop live HR: $e');
      }
    }
    await livePpi.reconcile(); // hands PPI back to the sensor
    if (dc.isConnected) {
      await syncNow(reason: 'after live');
    } else if (dc.connection == PolarConnectionState.connecting) {
      await _rest();
    }
  }

  /// Runs one sync round on the connected sensor.
  Future<void> syncNow({String reason = ''}) async {
    if (_running) {
      _queued = true;
      return;
    }
    final id = dc.deviceId;
    if (id == null || !dc.isConnected) {
      await connectAndSync(reason: reason);
      return;
    }
    _running = true;
    lastError = null;
    lastRunRecordings = 0;
    lastRunSamples = 0;
    _log('info', 'sync started${reason.isEmpty ? '' : ' ($reason)'}');
    try {
      await _run(id);
      lastSyncAt = DateTime.now();
      dataVersion++;
      _setPhase(
        SyncPhase.done,
        '$lastRunRecordings recording${lastRunRecordings == 1 ? '' : 's'}, $lastRunSamples samples',
      );
      _log(
        'info',
        'sync done: $lastRunRecordings recordings, $lastRunSamples samples',
      );
      if (_restartOwed) {
        await _armRetry();
      } else {
        await _clearRetry();
      }
    } catch (e) {
      lastError = '$e';
      _setPhase(SyncPhase.error, '$e');
      _log('error', 'sync failed: $e');
      if (recording == RecordingState.paused) {
        // Stopped for the fetch and never confirmed running again.
        await _setRecording(RecordingState.failed, problem: _interrupted);
        _restartOwed = true;
      }
      if (_restartOwed) await _armRetry();
    } finally {
      _running = false;
      _afterRun();
    }
    if (_queued) {
      _queued = false;
      unawaited(syncNow(reason: 'queued'));
    }
  }

  Future<void> _run(String id) async {
    // Clock first: every later sample is stamped with it.
    _setPhase(SyncPhase.settingTime, 'Setting sensor clock');
    await bridge.setLocalTime(id, DateTime.now());
    try {
      diskSpace = await bridge.getDiskSpace(id);
    } catch (e) {
      _log('warn', 'disk space: $e');
    }

    _setPhase(SyncPhase.stoppingRecordings, 'Closing recordings on the sensor');
    final running = await bridge.offlineRecordingStatus(id);
    for (final t in running) {
      try {
        await bridge.stopOfflineRecording(id, t);
      } on PolarException catch (e) {
        _log('warn', 'stop ${t.label}: $e');
      }
    }
    await _setRecording(RecordingState.paused);
    if (running.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    _setPhase(SyncPhase.listing, 'Listing recordings');
    final listed = await bridge.listOfflineRecordings(id).toList();
    // Only heart rate and movement are fetched. A pulse interval recording
    // (from before they were switched off) is removed from the sensor
    // unread; any other type stays there, untouched.
    final entries = <OfflineRecordingEntry>[];
    var skipped = 0;
    for (final e in listed) {
      if (supportedTypes.contains(e.type)) {
        entries.add(e);
      } else if (e.type == PolarDataType.ppi) {
        try {
          await bridge.removeOfflineRecord(id, e);
          _log(
            'info',
            'removed unread ${e.type.label} ${_fmt(e.date)} (${_kb(e.size)}) '
                'from the sensor',
          );
        } on PolarException catch (err) {
          _log('warn', 'remove ${e.type.label} on sensor: $err');
        }
      } else {
        skipped++;
      }
    }
    entries.sort((a, b) => a.date.compareTo(b.date));
    _log(
      'info',
      '${entries.length} recordings on sensor'
          '${skipped == 0 ? '' : ' ($skipped of other types left there)'}',
    );

    // Recording starts again before the fetch, not after it: the closed
    // recordings are listed, so the new ones cannot be mistaken for them,
    // and the sensor is stopped for seconds instead of for the whole
    // transfer. A link lost during the fetch then leaves it recording.
    _setPhase(SyncPhase.restartingRecordings, 'Arming recordings');
    final problems = await _ensureRecording(id);
    await _confirmRecording(id, problems);
    await _ensureTrigger(id);

    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final label = '${e.type.label} ${_fmt(e.date)} (${_kb(e.size)})';
      _setPhase(SyncPhase.fetching, '${i + 1}/${entries.length} $label');
      progressPercent = 0;
      notifyListeners();
      PackedRecording? data;
      try {
        await for (final ev in bridge.fetchOfflineRecordingPacked(id, e)) {
          if (ev.isComplete) {
            data = ev.data;
          } else if (ev.progressPercent != null) {
            progressPercent = ev.progressPercent;
            notifyListeners();
          }
        }
      } on PolarException catch (err) {
        _log('warn', 'fetch $label: $err');
        if (err.message.contains('NO_SUCH_FILE')) continue;
        rethrow;
      }
      if (data == null) {
        _log('warn', 'fetch $label ended without data');
        continue;
      }
      _setPhase(SyncPhase.storing, 'Storing $label');
      final recId = await repo.storeRecording(id, data, path: e.path);
      if (data.type == PolarDataType.hr) {
        // The sensor's copy of these seconds is in; the live copy yields.
        final stored = await repo.recording(recId);
        if (stored != null) liveHr.covered(stored.startMs, stored.endMs);
      }
      lastRunRecordings++;
      lastRunSamples += data.sampleCount;
      dataVersion++; // the graphs pick up each recording as it lands
      _log('info', 'stored #$recId $label: ${data.sampleCount} samples');
      try {
        await bridge.removeOfflineRecord(id, e);
      } on PolarException catch (err) {
        _log('warn', 'delete $label on sensor: $err');
      }
    }
    progressPercent = null;

    // The last word before leaving: is the sensor still recording after the
    // transfer? Only a change is acted on, so the status keeps its time.
    final wanted = settings.recordTypes;
    final still = (await bridge.offlineRecordingStatus(id)).toSet();
    if (recording == RecordingState.recording && !still.containsAll(wanted)) {
      _log('warn', 'recording stopped during the sync; starting it again');
      _setPhase(SyncPhase.restartingRecordings, 'Arming recordings');
      await _confirmRecording(id, await _ensureRecording(id));
    }

    final removed = await repo.retention(days: settings.retentionDays);
    if (removed > 0) _log('info', 'retention removed $removed recordings');
  }

  Future<SensorSetting?> _settingFor(String id, PolarDataType type) async {
    if (!type.needsSettings) return null;
    if (type != PolarDataType.acc) return null;
    final wanted = settings.accSetting();
    try {
      final options = await bridge.requestOfflineRecordingSettings(id, type);
      return snapSensorSetting(options, wanted);
    } on PolarException catch (e) {
      _log('warn', 'offline settings for ${type.label}: $e');
      return wanted;
    }
  }

  Future<void> _ensureTrigger(String id) async {
    final features = <PolarDataType, SensorSetting?>{};
    for (final t in settings.recordTypes) {
      features[t] = await _settingFor(id, t);
    }
    final wanted = OfflineRecordingTrigger(
      mode: TriggerMode.systemStart,
      features: features,
    );
    OfflineRecordingTrigger? current;
    try {
      current = await bridge.offlineRecordingTriggerSetup(id);
    } on PolarException catch (e) {
      _log('warn', 'read trigger: $e');
    }
    if (current != null && _sameTrigger(current, wanted)) return;
    try {
      await bridge.setOfflineRecordingTrigger(id, wanted);
      _log(
        'info',
        'trigger set: start on power-on for ${features.keys.map((t) => t.label).join(', ')}',
      );
    } on PolarException catch (e) {
      _log('error', 'set trigger: $e');
    }
  }

  static String _typeName(PolarDataType t) => switch (t) {
    PolarDataType.hr => 'Heart rate',
    PolarDataType.acc => 'Movement',
    _ => t.label,
  };

  bool _sameTrigger(OfflineRecordingTrigger a, OfflineRecordingTrigger b) {
    if (a.mode != b.mode) return false;
    if (a.features.keys
            .toSet()
            .difference(b.features.keys.toSet())
            .isNotEmpty ||
        b.features.keys
            .toSet()
            .difference(a.features.keys.toSet())
            .isNotEmpty) {
      return false;
    }
    for (final t in b.features.keys) {
      final x = a.features[t]?.values[SettingType.sampleRate];
      final y = b.features[t]?.values[SettingType.sampleRate];
      if (x != y) return false;
    }
    return true;
  }

  /// Starts the wanted recordings that are not running. Returns, per type
  /// that could not be started, why.
  Future<Map<PolarDataType, String>> _ensureRecording(String id) async {
    final problems = <PolarDataType, String>{};
    final running = (await bridge.offlineRecordingStatus(id)).toSet();
    for (final t in settings.recordTypes) {
      if (running.contains(t)) continue;
      if (t == PolarDataType.ppi && livePpi.holdsPpi) continue;
      try {
        await bridge.startOfflineRecording(
          id,
          t,
          settings: await _settingFor(id, t),
        );
        _log('info', 'recording ${t.label} started');
      } on PolarException catch (e) {
        problems[t] = '$e';
        _log('error', 'start ${t.label} recording: $e');
      }
    }
    return problems;
  }

  /// Asks the sensor what it is recording now and sets [recording] from the
  /// answer, not from the start commands having returned.
  Future<void> _confirmRecording(
    String id,
    Map<PolarDataType, String> problems,
  ) async {
    final wanted = settings.recordTypes;
    final running = (await bridge.offlineRecordingStatus(id))
        .toSet()
        .intersection(wanted);
    final missing = wanted.difference(running);
    if (wanted.isEmpty) {
      _restartOwed = false;
      await _setRecording(
        RecordingState.failed,
        problem: 'Nothing is selected to record (Settings).',
      );
    } else if (missing.isEmpty) {
      _restartOwed = false;
      await _setRecording(RecordingState.recording, types: running);
      // Always: the alert may be from before this process started.
      try {
        await bridge.alertClear();
      } catch (e) {
        _log('warn', 'alert not cleared: $e');
      }
      _log(
        'info',
        'sensor confirms recording: ${running.map((t) => t.label).join(', ')}',
      );
    } else {
      final why = problems.values.join(' ');
      _restartOwed = !why.contains('ERROR_DEVICE_IN_CHARGER');
      final problem = why.contains('ERROR_DEVICE_IN_CHARGER')
          ? 'The sensor is in the charger.'
          : why.isEmpty
          ? 'The sensor did not start it.'
          : why;
      await _setRecording(
        RecordingState.failed,
        types: running,
        problem:
            '${missing.map(_typeName).join(' and ')} not recording. '
            '$problem',
      );
      _log('error', 'not recording: ${missing.map((t) => t.label).join(', ')}');
    }
  }

  // ---- lifecycle ------------------------------------------------------------

  void _afterRun() {
    if (_queued) {
      // Another run follows at once; decide after it.
    } else if (liveRequested && dc.isConnected) {
      unawaited(_ensureLiveStreams());
    } else {
      unawaited(_rest());
    }
    notifyListeners();
  }

  /// Disconnects, waits until the sensor is really gone, runs [afterDevice]
  /// and only then releases the foreground service: nothing runs until the
  /// next trigger. The sync result stays on the dashboard.
  Future<void> _rest() async {
    _connectTimeout?.cancel();
    _idle?.cancel();
    if (dc.connection != PolarConnectionState.disconnected) {
      try {
        await bridge.setAutomaticReconnection(false);
        await dc.disconnect();
      } catch (e) {
        _log('warn', 'disconnect: $e');
      }
      await _untilDisconnected();
    }
    notifyListeners();
    final hook = afterDevice;
    if (hook != null && deviceIdle && !_finishing) {
      _finishing = true;
      try {
        await hook().timeout(afterDeviceLimit);
      } catch (e) {
        _log('warn', 'after the sync: $e');
      } finally {
        _finishing = false;
      }
    }
    await stopPresence();
    // A trigger that arrived meanwhile owns the service now.
    if (deviceIdle) await bridge.serviceIdle();
    notifyListeners();
  }

  /// Stops Android's watch for the sensor coming into range. The Polar SDK
  /// starts it when it is created and again before every connect, so this
  /// runs at app start and after every connection.
  ///
  /// Why (2026-11-22): the watch reported the worn sensor lost and found
  /// again every half minute, some hundred times a day. Each time Android
  /// woke the app and started the foreground service for nothing, and the
  /// lines filled half the sync log. Nothing syncs on presence any more: the
  /// schedule, the app start, coming to the foreground and "Sync" do.
  Future<void> stopPresence() async {
    try {
      await bridge.companionStopObserving();
    } catch (e) {
      _log('warn', 'presence watch not stopped: $e');
    }
  }

  /// Completes when the disconnect event has arrived (10 s at most).
  Future<void> _untilDisconnected() async {
    bool gone() => dc.connection == PolarConnectionState.disconnected;
    if (gone()) return;
    final done = Completer<void>();
    void check() {
      if (gone() && !done.isCompleted) done.complete();
    }

    dc.addListener(check);
    try {
      await done.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _log('warn', 'no disconnect event within 10 s');
    } finally {
      dc.removeListener(check);
    }
  }

  /// Fallback for disconnects we did not ask for: release the service once
  /// nothing is pending.
  void _scheduleIdleCheck() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 20), () async {
      if (!_running && !dc.isConnected && !liveRequested && !_finishing) {
        if (phase != SyncPhase.done && phase != SyncPhase.error) {
          _setPhase(
            settings.isPaired ? SyncPhase.waitingForDevice : SyncPhase.idle,
            '',
          );
        }
        await bridge.serviceIdle();
      }
    });
  }

  /// The user's "Disconnect": ends a live session without the closing sync.
  Future<void> disconnect() async {
    _syncOnReady = false;
    if (liveRequested) {
      liveRequested = false;
      _log('info', 'live ended (disconnect)');
    }
    await _rest();
    _setPhase(SyncPhase.idle, '');
  }

  void _setPhase(SyncPhase p, String d) {
    phase = p;
    detail = d;
    if (p != SyncPhase.fetching) progressPercent = null;
    if (p != SyncPhase.done && p != SyncPhase.error && p != SyncPhase.idle) {
      unawaited(bridge.serviceNotification('heild · ${_phaseLabel(p)}', d));
    }
    notifyListeners();
  }

  String _phaseLabel(SyncPhase p) => switch (p) {
    SyncPhase.idle => 'idle',
    SyncPhase.waitingForDevice => 'waiting for sensor',
    SyncPhase.connecting => 'connecting',
    SyncPhase.settingTime => 'syncing',
    SyncPhase.stoppingRecordings => 'syncing',
    SyncPhase.listing => 'syncing',
    SyncPhase.fetching => 'fetching',
    SyncPhase.storing => 'storing',
    SyncPhase.restartingRecordings => 'arming recordings',
    SyncPhase.done => 'done',
    SyncPhase.error => 'error',
  };

  void _log(String level, String message) {
    dc.log('[sync] $message');
    unawaited(repo.log(level, message));
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _kb(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} kB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  void dispose() {
    _events.cancel();
    dc.removeListener(_onDeviceChanged);
    settings.removeListener(_onSettings);
    _connectTimeout?.cancel();
    _idle?.cancel();
    super.dispose();
  }
}
