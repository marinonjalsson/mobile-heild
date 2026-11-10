import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../polar/models.dart';
import '../polar/packed_recording.dart';
import '../polar/polar_bridge.dart';
import '../polar/polar_errors.dart';
import 'app_settings.dart';
import 'device_controller.dart';
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

  /// Tells viewers that stored data changed outside a sync.
  void dataChanged() {
    dataVersion++;
    notifyListeners();
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
  DateTime? _lastAppeared;
  DateTime? _lastDisappeared;
  int? _scheduledHours;

  /// The user asked for live data; the connection stays up while true.
  bool liveRequested = false;
  bool _liveStarting = false;

  /// Give up on a connect attempt after this: the sensor is off or away.
  static const connectTimeout = Duration(seconds: 90);

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

  bool _matchesPaired(String? identifier) {
    if (identifier == null) return true;
    final id = identifier.toUpperCase();
    return id == settings.pairedDeviceId?.toUpperCase() ||
        id == settings.pairedAddress?.toUpperCase();
  }

  // ---- triggers -------------------------------------------------------------

  void _onEvent(PolarEvent e) {
    switch (e.type) {
      case 'companionDeviceAppeared':
        // The SDK registers one presence listener per connection, so a single
        // event arrives several times; act on it once.
        final now = DateTime.now();
        if (_lastAppeared != null &&
            now.difference(_lastAppeared!) < const Duration(seconds: 15)) {
          return;
        }
        _lastAppeared = now;
        _log('info', 'sensor in range (${e.identifier})');
        if (settings.autoSync && _matchesPaired(e.identifier)) {
          unawaited(connectAndSync(reason: 'sensor appeared'));
        } else if (!dc.isConnected && !_running) {
          // The presence service started the foreground service; not needed.
          unawaited(bridge.serviceIdle());
        }
      case 'companionDeviceDisappeared':
        final now = DateTime.now();
        if (_lastDisappeared != null &&
            now.difference(_lastDisappeared!) < const Duration(seconds: 15)) {
          return;
        }
        _lastDisappeared = now;
        _log('info', 'sensor out of range (${e.identifier})');
        _scheduleIdleCheck();
      case 'scheduledSync':
        _log('info', 'scheduled sync');
        unawaited(connectAndSync(reason: 'scheduled'));
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
          dc.featuresReady.contains('FEATURE_HR') &&
          !dc.streams.containsKey(PolarDataType.hr)) {
        unawaited(_ensureLiveStreams());
      }
    } else if (dc.connection == PolarConnectionState.disconnected) {
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
      _log('warn', 'sensor not found within ${connectTimeout.inSeconds} s');
      _setPhase(SyncPhase.error, 'Sensor not in range');
      if (liveRequested) {
        liveRequested = false;
        notifyListeners();
      }
      await _rest();
    });
  }

  /// Connects to the paired sensor (or [deviceId]) and syncs once ready.
  Future<void> connectAndSync({String? deviceId, String reason = ''}) async {
    final id = deviceId ?? settings.pairedDeviceId;
    if (id == null) {
      _setPhase(SyncPhase.error, 'No sensor paired');
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
      await _rest();
    }
  }

  // ---- live session ---------------------------------------------------------

  /// Connects (if needed) and streams HR to the dashboard until [stopLive].
  Future<void> startLive() async {
    final id = settings.pairedDeviceId;
    if (id == null || liveRequested) return;
    liveRequested = true;
    notifyListeners();
    _log('info', 'live started');
    _idle?.cancel();
    await bridge.serviceStart();
    if (dc.isConnected && dc.deviceId == id) {
      if (!_running) await _ensureLiveStreams();
      return;
    }
    if (dc.connection == PolarConnectionState.connecting) return;
    await _connect(id, 'live');
  }

  Future<void> _ensureLiveStreams() async {
    if (_liveStarting || !liveRequested || !dc.isConnected) return;
    _liveStarting = true;
    try {
      if (!dc.streams.containsKey(PolarDataType.hr)) {
        await dc.startStream(PolarDataType.hr);
      }
      unawaited(
        bridge.serviceNotification(
          'Live · ${settings.pairedName ?? dc.deviceId}',
          'Streaming heart rate to the dashboard',
        ),
      );
    } catch (e) {
      _log('warn', 'live HR: $e');
    } finally {
      _liveStarting = false;
    }
    _log(
      'info',
      'live HR streaming; PP intervals ${livePpi.wantsStream ? 'wanted' : 'not wanted'}',
    );
    unawaited(livePpi.reconcile());
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
    } catch (e) {
      lastError = '$e';
      _setPhase(SyncPhase.error, '$e');
      _log('error', 'sync failed: $e');
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
    if (running.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    _setPhase(SyncPhase.listing, 'Listing recordings');
    final entries = await bridge.listOfflineRecordings(id).toList();
    entries.sort((a, b) => a.date.compareTo(b.date));
    _log('info', '${entries.length} recordings on sensor');

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
      _log('info', 'stored #$recId $label: ${data.sampleCount} samples');
      try {
        await bridge.removeOfflineRecord(id, e);
      } on PolarException catch (err) {
        _log('warn', 'delete $label on sensor: $err');
      }
    }
    progressPercent = null;

    _setPhase(SyncPhase.restartingRecordings, 'Arming recordings');
    await _ensureTrigger(id);
    await _ensureRecording(id);

    final removed = await repo.retention(days: settings.retentionDays);
    if (removed > 0) _log('info', 'retention removed $removed recordings');
  }

  Future<SensorSetting?> _settingFor(String id, PolarDataType type) async {
    if (!type.needsSettings) return null;
    if (type != PolarDataType.acc) return null;
    final wanted = settings.accSetting();
    try {
      final options = await bridge.requestOfflineRecordingSettings(id, type);
      // The device wants every setting type it offers (CHANNELS included), so
      // start from its option list and snap our preferences onto it.
      final picked = <SettingType, int>{};
      for (final e in options.options.entries) {
        if (e.value.isEmpty) continue;
        final want = wanted.values[e.key];
        picked[e.key] = want != null && e.value.contains(want)
            ? want
            : e.value.first;
      }
      return picked.isEmpty ? wanted : SensorSetting(picked);
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

  Future<void> _ensureRecording(String id) async {
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
        _log('error', 'start ${t.label} recording: $e');
      }
    }
  }

  // ---- lifecycle ------------------------------------------------------------

  void _afterRun() {
    if (_queued) {
      // Another run follows at once; decide after it.
    } else if (liveRequested && dc.isConnected) {
      unawaited(_ensureLiveStreams());
    } else if (dc.connection != PolarConnectionState.disconnected) {
      unawaited(_rest());
    } else {
      unawaited(bridge.serviceIdle());
    }
    notifyListeners();
  }

  /// Disconnects and releases the foreground service: nothing runs until
  /// the next trigger. The sync result stays on the dashboard.
  Future<void> _rest() async {
    _connectTimeout?.cancel();
    _idle?.cancel();
    try {
      await bridge.setAutomaticReconnection(false);
      await dc.disconnect();
    } catch (e) {
      _log('warn', 'disconnect: $e');
    }
    await bridge.serviceIdle();
    notifyListeners();
  }

  /// Fallback for disconnects we did not ask for: release the service once
  /// nothing is pending.
  void _scheduleIdleCheck() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 20), () async {
      if (!_running && !dc.isConnected && !liveRequested) {
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
