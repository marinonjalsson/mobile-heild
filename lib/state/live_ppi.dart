import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../polar/models.dart';
import '../polar/packed_recording.dart';
import '../polar/polar_bridge.dart';
import '../polar/polar_errors.dart';
import 'app_settings.dart';
import 'device_controller.dart';

/// What the live PP-interval stream says about the pulse right now.
enum PulseState {
  /// No PPI stream running; the dashboard falls back to its time-based rule.
  off,

  /// Stream started, first batch not in yet (the sensor needs ~25 s).
  warmingUp,

  /// At least one good beat in the last [LivePpiService.goodWindow].
  good,

  /// Batches arrive but every beat is blocked or too noisy.
  poor,

  /// No batch for [LivePpiService.lostAfter].
  lost,
}

/// One live PP-interval session. Live PPI samples carry no timestamps, so each
/// batch is stamped with its arrival time; the recording start is the first
/// arrival minus the intervals in that batch, and the repository derives the
/// per-sample times by accumulating intervals, exactly as for offline PPI.
class PpiSession {
  PpiSession(this.deviceId);

  final String deviceId;

  /// Error estimates above this (ms) mean movement or a loose strap (SDK doc).
  static const goodErrorMs = 30;

  int? startMs;
  int? lastBatchMs;
  final ppi = <int>[];
  final errorEstimate = <int>[];
  final hr = <int>[];

  /// bit0 blocker, bit1 skin contact, bit2 skin contact supported — the same
  /// packing the Kotlin side uses for offline PPI.
  final flags = <int>[];

  /// Arrival time of the batch each sample came in.
  final arrivedMs = <int>[];

  int get length => ppi.length;

  void addBatch(int nowMs, Iterable<PpiSample> samples) {
    final list = samples.toList();
    if (list.isEmpty) return;
    if (startMs == null) {
      var sum = 0;
      for (final s in list) {
        sum += s.ppi;
      }
      startMs = nowMs - sum;
    }
    lastBatchMs = nowMs;
    for (final s in list) {
      ppi.add(s.ppi);
      errorEstimate.add(s.errorEstimate);
      hr.add(s.hr);
      flags.add(
        (s.blockerBit ? 1 : 0) |
            (s.skinContactStatus ? 2 : 0) |
            (s.skinContactSupported ? 4 : 0),
      );
      arrivedMs.add(nowMs);
    }
  }

  static bool isGood(int flag, int errorEstimate) =>
      (flag & 1) == 0 && errorEstimate <= goodErrorMs;

  /// Good beats that arrived at or after [sinceMs].
  int goodBeatsSince(int sinceMs) {
    var n = 0;
    for (var i = 0; i < ppi.length; i++) {
      if (arrivedMs[i] >= sinceMs && isGood(flags[i], errorEstimate[i])) n++;
    }
    return n;
  }

  /// RMSSD over consecutive good beats that arrived at or after [sinceMs];
  /// null with fewer than two differences. A bad beat breaks the sequence.
  double? rmssdSince(int sinceMs) {
    var d2 = 0.0;
    var n = 0;
    int? prev;
    for (var i = 0; i < ppi.length; i++) {
      if (arrivedMs[i] < sinceMs) continue;
      if (!isGood(flags[i], errorEstimate[i])) {
        prev = null;
        continue;
      }
      if (prev != null) {
        final d = ppi[i] - prev;
        d2 += d * d;
        n++;
      }
      prev = ppi[i];
    }
    return n >= 2 ? math.sqrt(d2 / n) : null;
  }

  /// The session as a recording the repository can store (null while empty).
  PackedRecording? toPacked() {
    final start = startMs;
    if (start == null || ppi.isEmpty) return null;
    return PackedRecording(
      type: PolarDataType.ppi,
      startTimeIso: DateTime.fromMillisecondsSinceEpoch(start)
          .toIso8601String(),
      settings: null,
      sampleCount: ppi.length,
      ts: Int64List(ppi.length),
      ppi: Int32List.fromList(ppi),
      errorEstimate: Int32List.fromList(errorEstimate),
      hr: Int32List.fromList(hr),
      flags: Uint8List.fromList(flags),
    );
  }
}

/// Streams PP intervals while the app is in the foreground and connected,
/// instead of letting the sensor record them. Gives the dashboard a real
/// pulse-found / pulse-lost signal (blocker bit and error estimate per beat)
/// and stores the beats on the phone as a `live` recording. When the app goes
/// to the background the stream stops and the sensor's PPI recording is armed
/// again. The sensor cannot do both at once, hence the hand-over.
class LivePpiService extends ChangeNotifier {
  LivePpiService(
    this.bridge,
    this.dc,
    this.repo,
    this.settings, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    dc.addListener(_onDevice);
    settings.addListener(_onSettings);
  }

  final PolarBridge bridge;
  final DeviceController dc;
  final Repository repo;
  final AppSettings settings;
  final DateTime Function() _clock;

  static const goodWindow = Duration(seconds: 15);
  static const lostAfter = Duration(seconds: 20);
  static const warmUp = Duration(seconds: 40);
  static const flushEvery = Duration(seconds: 60);

  /// Set by the app controller from the app lifecycle.
  bool get foreground => _foreground;
  bool _foreground = false;
  set foreground(bool v) {
    if (v == _foreground) return;
    _foreground = v;
    _log('info', v ? 'app in foreground' : 'app in background');
    unawaited(reconcile());
  }

  /// The sync service is mid-run; starting a stream then would race it.
  bool Function() syncBusy = () => false;

  /// The live session is about pulse intervals (sync service); otherwise the
  /// sensor keeps PPI for itself.
  bool Function() liveWanted = () => false;

  /// Called after each successful flush (the viewers re-read).
  void Function() dataChanged = () {};

  PpiSession? session;
  DateTime? streamStartedAt;
  String? lastError;

  bool _owned = false;
  bool _busy = false;
  bool _pending = false;
  int _seenBatches = 0;
  Timer? _flush;

  /// Live PPI should be streaming now.
  bool get wantsStream =>
      settings.recordTypes.contains(PolarDataType.ppi) &&
      dc.isConnected &&
      _foreground &&
      liveWanted();

  /// True while a PPI stream is running (ours or started from the panel).
  bool get streaming => dc.streams.containsKey(PolarDataType.ppi);

  /// The sync must leave the sensor's PPI recording alone.
  bool get holdsPpi => streaming || wantsStream;

  PulseState get state {
    if (!streaming) return PulseState.off;
    final s = session;
    final now = _clock();
    final last = s?.lastBatchMs;
    if (last == null) {
      final since = streamStartedAt;
      return since != null && now.difference(since) < warmUp
          ? PulseState.warmingUp
          : PulseState.lost;
    }
    if (now.millisecondsSinceEpoch - last > lostAfter.inMilliseconds) {
      return PulseState.lost;
    }
    return s!.goodBeatsSince(
              now.millisecondsSinceEpoch - goodWindow.inMilliseconds,
            ) >
            0
        ? PulseState.good
        : PulseState.poor;
  }

  /// RMSSD of the last minute of good beats, for the dashboard.
  double? get rmssdLastMinute =>
      session?.rmssdSince(_clock().millisecondsSinceEpoch - 60000);

  DateTime? get lastBatchAt {
    final ms = session?.lastBatchMs;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Starts or stops the stream so it matches [wantsStream]. Safe to call often.
  Future<void> reconcile() async {
    if (_busy) {
      _pending = true;
      return;
    }
    _busy = true;
    try {
      final id = dc.deviceId;
      if (wantsStream && !_owned && !streaming && id != null) {
        if (!syncBusy()) await _start(id);
      } else if (!wantsStream && _owned) {
        await _stop(id);
      }
    } finally {
      _busy = false;
    }
    if (_pending) {
      _pending = false;
      unawaited(reconcile());
    }
  }

  Future<void> _start(String id) async {
    lastError = null;
    try {
      final running = await bridge.offlineRecordingStatus(id);
      if (running.contains(PolarDataType.ppi)) {
        await bridge.stopOfflineRecording(id, PolarDataType.ppi);
        _log('info', 'PPI recording stopped for live streaming');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      session = PpiSession(id);
      _seenBatches = 0;
      await _startStreamChecked(id);
      _owned = true;
      streamStartedAt = _clock();
      _flush?.cancel();
      _flush = Timer.periodic(flushEvery, (_) => unawaited(flush()));
      _log('info', 'live PP intervals started');
    } on PolarException catch (e) {
      lastError = '$e';
      _log('error', 'live PP intervals failed: $e');
      session = null;
      await _armRecording(id);
    }
    notifyListeners();
  }

  /// Starts the stream and waits long enough to see an immediate rejection
  /// (the bridge reports those asynchronously). One retry for the sensor still
  /// closing its recording.
  Future<void> _startStreamChecked(String id) async {
    for (var attempt = 0; ; attempt++) {
      await dc.startStream(PolarDataType.ppi);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final err = dc.streamErrors[PolarDataType.ppi];
      if (err == null && streaming) return;
      final text = '$err';
      if (attempt == 0 && text.contains('ALREADY_IN_STATE')) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      throw err is PolarException ? err : PolarException('Stream', text);
    }
  }

  Future<void> _stop(String? id) async {
    _flush?.cancel();
    _flush = null;
    // Not ours any more before the stream's onDone fires, or _onDevice would
    // treat the stop as the stream ending under us and flush a second time.
    _owned = false;
    await dc.stopStream(PolarDataType.ppi);
    final n = session?.length ?? 0;
    await flush();
    _log('info', 'live PP intervals stopped ($n samples)');
    session = null;
    streamStartedAt = null;
    if (id != null &&
        dc.isConnected &&
        settings.recordTypes.contains(PolarDataType.ppi)) {
      await _armRecording(id);
    }
    notifyListeners();
  }

  Future<void> _armRecording(String id) async {
    try {
      final running = await bridge.offlineRecordingStatus(id);
      if (running.contains(PolarDataType.ppi)) return;
      await bridge.startOfflineRecording(id, PolarDataType.ppi);
      _log('info', 'recording PP interval started');
    } on PolarException catch (e) {
      _log('error', 'start PP interval recording: $e');
    }
  }

  /// Writes the session so far as one recording (replaces the previous flush).
  Future<void> flush() async {
    final s = session;
    final packed = s?.toPacked();
    if (s == null || packed == null) return;
    try {
      await repo.storeRecording(s.deviceId, packed, source: 'live');
      dataChanged();
    } catch (e) {
      _log('warn', 'store live PP intervals: $e');
    }
  }

  void _onDevice() {
    final active = dc.streams[PolarDataType.ppi];
    if (active != null) {
      final batch = active.latest;
      if (batch != null && active.batches != _seenBatches) {
        _seenBatches = active.batches;
        final id = dc.deviceId;
        if (id != null) {
          (session ??= PpiSession(id)).addBatch(
            _clock().millisecondsSinceEpoch,
            batch.samples.map(PpiSample.fromMap),
          );
        }
        notifyListeners();
      }
    } else if (_owned) {
      // The stream ended under us (disconnect, or stopped from the panel).
      _owned = false;
      _flush?.cancel();
      _flush = null;
      final n = session?.length ?? 0;
      unawaited(
        flush().then((_) {
          _log('info', 'live PP intervals ended ($n samples)');
          session = null;
          streamStartedAt = null;
          notifyListeners();
        }),
      );
    }
  }

  void _onSettings() => unawaited(reconcile());

  void _log(String level, String message) {
    dc.log('[live] $message');
    unawaited(repo.log(level, message));
  }

  @override
  void dispose() {
    dc.removeListener(_onDevice);
    settings.removeListener(_onSettings);
    _flush?.cancel();
    super.dispose();
  }
}
