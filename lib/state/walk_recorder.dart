import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../walk/models.dart';
import '../walk/track.dart';
import '../walk/walk_bridge.dart';

/// Records a walk: GPS fixes from [start] to [stop], stored in `walks` and
/// `walk_points`.
///
/// The fixes come from a foreground service of their own (`WalkService.kt`),
/// so recording goes on with the screen off and is not touched by the sensor
/// sync, which stops its own service after every round.
///
/// Fixes are kept in memory and written every [flushEvery]; a killed process
/// loses at most that much, and [init] ends the walk it left open.
///
/// Only the Walks tab listens to this. It notifies on every fix, about once a
/// second, and is deliberately **not** forwarded through the app controller:
/// that would rebuild every tab every second.
class WalkRecorder extends ChangeNotifier {
  WalkRecorder(this._bridge, this._repo, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const flushEvery = Duration(seconds: 10);

  final WalkBridge _bridge;
  final Repository _repo;
  final DateTime Function() _now;

  /// Asks for the location permission (a system dialog); false when refused.
  Future<bool> Function() ensurePermission = () async => true;

  /// Called when a walk was finished (starts an upload).
  VoidCallback? onFinished;

  bool _recording = false;
  bool _busy = false;
  int? _walkId;
  int? _startMs;
  var _meter = TrackMeter();
  final _points = <WalkPoint>[];
  int _stored = 0;
  StreamSubscription<WalkPoint>? _sub;
  Timer? _flushTimer;
  Future<void> _flushing = Future.value();

  bool get recording => _recording;

  /// Start or Stop is being carried out.
  bool get busy => _busy;

  /// When the running walk started.
  DateTime? get startedAt =>
      _startMs == null ? null : DateTime.fromMillisecondsSinceEpoch(_startMs!);

  /// Every fix of the running walk, in order (for the map).
  List<WalkPoint> get points => _points;

  /// The newest fix, null while GPS is still looking for one.
  WalkPoint? get last => _points.isEmpty ? null : _points.last;

  double get distanceM => _meter.distanceM;

  /// Why the last [start] did not start, in words for the page.
  String? error;

  /// Grows whenever the stored walks changed; the list on the page keys on it.
  int version = 0;

  /// At app start: nothing can be recording, so whatever is open was cut off.
  Future<void> init() async {
    try {
      // A Dart restart with the service still up (hot restart): its fixes
      // have nowhere to go.
      if (await _bridge.isRunning()) await _bridge.stop();
    } catch (_) {}
    await _repo.closeOpenWalks();
  }

  Future<void> start() async {
    if (_recording || _busy) return;
    _busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await ensurePermission()) {
        error = 'heild needs the precise location permission to record a walk.';
        return;
      }
      await _bridge.start();
      _startMs = _now().millisecondsSinceEpoch;
      _walkId = await _repo.createWalk(_startMs!);
      _meter = TrackMeter();
      _points.clear();
      _stored = 0;
      _recording = true;
      _sub = _bridge.points().listen(_onPoint);
      _flushTimer = Timer.periodic(flushEvery, (_) => flush());
    } on PlatformException catch (e) {
      error = switch (e.code) {
        'NoPreciseLocation' =>
          'heild needs the precise location permission to record a walk. '
              'Approximate location is not enough.',
        'LocationOff' => 'Location is switched off on the phone.',
        _ => 'The walk could not be started: ${e.message ?? e.code}',
      };
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _onPoint(WalkPoint p) {
    if (!_recording) return;
    // Android may repeat a fix; the table is keyed on the time.
    if (_points.isNotEmpty && p.tsMs <= _points.last.tsMs) return;
    _points.add(p);
    _meter.add(p);
    notifyListeners();
  }

  /// Writes the fixes that are not in the database yet. One at a time.
  Future<void> flush() {
    return _flushing = _flushing.then((_) async {
      final id = _walkId;
      if (id == null || _stored >= _points.length) return;
      final upTo = _points.length;
      final distance = _meter.distanceM;
      try {
        await _repo.appendWalkPoints(
          id,
          _points.sublist(_stored, upTo),
          distance,
        );
        _stored = upTo;
      } catch (e) {
        // Kept in memory; the next flush tries the same fixes again.
        await _repo.log('warn', 'walk: fixes not stored: $e');
      }
    });
  }

  Future<void> stop() async {
    if (!_recording || _busy) return;
    _busy = true;
    _recording = false;
    notifyListeners();
    try {
      _flushTimer?.cancel();
      _flushTimer = null;
      await _sub?.cancel();
      _sub = null;
      try {
        await _bridge.stop();
      } catch (_) {}
      await flush();
      final id = _walkId!;
      if (_stored == 0) {
        // Stopped before GPS found anything: not a walk.
        await _repo.deleteWalk(id);
      } else {
        await _repo.finishWalk(
          id,
          _now().millisecondsSinceEpoch,
          _meter.distanceM,
        );
        onFinished?.call();
      }
    } finally {
      _walkId = null;
      _startMs = null;
      _busy = false;
      version++;
      notifyListeners();
    }
  }

  Future<void> delete(int walkId) async {
    await _repo.deleteWalk(walkId);
    version++;
    notifyListeners();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
