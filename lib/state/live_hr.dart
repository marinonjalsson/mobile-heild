import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../polar/models.dart';
import '../polar/packed_recording.dart';
import 'device_controller.dart';

/// Live heart-rate samples collected since the last sync. Each sample is
/// stamped on arrival (the BLE heart-rate service sends one per second with
/// no timestamp). [covered] drops the seconds an offline recording now holds.
class LiveHrSession {
  LiveHrSession(this.deviceId);

  final String deviceId;
  final tsMs = <int>[];
  final hr = <int>[];

  /// bit0 skin contact, bit1 contact supported — the offline HR packing.
  final flags = <int>[];

  /// Id of the stored copy, so a flush can replace it even after the start
  /// moved because [covered] removed the first samples.
  int? storedId;

  /// Samples added since the last flush.
  bool dirty = false;

  int get length => hr.length;
  int? get startMs => tsMs.isEmpty ? null : tsMs.first;

  void add(int nowMs, HrSample s) {
    tsMs.add(nowMs);
    hr.add(s.hr);
    flags.add((s.contactStatus ? 1 : 0) | (s.contactStatusSupported ? 2 : 0));
    dirty = true;
  }

  /// Removes the samples an offline recording spanning [fromMs, toMs] holds.
  /// Its last sample at [toMs] stands for the second that follows, so the
  /// cut reaches toMs + 999. Returns how many samples went.
  int covered(int fromMs, int toMs) {
    var removed = 0;
    for (var i = tsMs.length - 1; i >= 0; i--) {
      if (tsMs[i] >= fromMs && tsMs[i] <= toMs + 999) {
        tsMs.removeAt(i);
        hr.removeAt(i);
        flags.removeAt(i);
        removed++;
      }
    }
    if (removed > 0) dirty = true;
    return removed;
  }

  PackedRecording? toPacked() {
    final start = startMs;
    if (start == null) return null;
    return PackedRecording(
      type: PolarDataType.hr,
      startTimeIso: DateTime.fromMillisecondsSinceEpoch(start)
          .toIso8601String(),
      settings: null,
      sampleCount: hr.length,
      ts: null,
      hr: Int32List.fromList(hr),
      flags: Uint8List.fromList(flags),
    );
  }
}

/// Stores the live heart rate on the phone as a `live` recording so the graphs
/// show it before the next sync. The sensor records HR too (the one type that
/// can stream and record at once); when its recording is fetched, the live
/// copy of those seconds is dropped, so nothing is counted twice.
class LiveHrService extends ChangeNotifier {
  LiveHrService(this.dc, this.repo, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    dc.addListener(_onDevice);
  }

  final DeviceController dc;
  final Repository repo;
  final DateTime Function() _clock;

  static const flushEvery = Duration(seconds: 60);

  /// A session this long without a sync is closed and a new one started.
  static const maxSession = 6 * 3600;

  /// Called after each successful flush (the viewers re-read).
  void Function() dataChanged = () {};

  LiveHrSession? session;
  Timer? _flush;
  int _seenBatches = -1;
  HrSample? _seenNotification;
  bool _flushing = false;

  void _onDevice() {
    final active = dc.streams[PolarDataType.hr];
    HrSample? s;
    if (active != null) {
      final batch = active.latest;
      if (batch == null || active.batches == _seenBatches) return;
      _seenBatches = active.batches;
      final samples = batch.samples;
      if (samples.isEmpty) return;
      s = HrSample.fromMap(samples.last);
    } else {
      final n = dc.lastHrNotification;
      if (n == null || identical(n, _seenNotification)) return;
      _seenNotification = n;
      s = n;
    }
    final id = dc.deviceId;
    if (id == null) return;
    var cur = session;
    if (cur != null && (cur.deviceId != id || cur.length >= maxSession)) {
      unawaited(flush(cur));
      cur = null;
    }
    cur ??= session = LiveHrSession(id);
    cur.add(_clock().millisecondsSinceEpoch, s);
    _flush ??= Timer.periodic(flushEvery, (_) => unawaited(flush()));
  }

  /// An offline HR recording covering [fromMs, toMs] was stored: forget our
  /// copy of those seconds and rewrite the stored session without them.
  void covered(int fromMs, int toMs) {
    final s = session;
    if (s == null) return;
    if (s.covered(fromMs, toMs) > 0) unawaited(flush());
  }

  /// Writes [which] (default: the current session) as one `live` recording,
  /// replacing the earlier copy. Runs again right away if samples arrived or
  /// were covered while the write was in flight.
  Future<void> flush([LiveHrSession? which]) async {
    final s = which ?? session;
    if (s == null || !s.dirty) return;
    if (_flushing) return; // the running flush re-checks `dirty` when done
    _flushing = true;
    try {
      while (s.dirty) {
        if (s.length == 0) {
          // Everything was covered by the sensor's recording; the repository
          // removed the emptied row already. Start afresh.
          s.dirty = false;
          if (identical(session, s)) session = null;
          break;
        }
        final packed = s.toPacked()!;
        final ts = List<int>.of(s.tsMs);
        s.dirty = false;
        s.storedId = await repo.storeRecording(
          s.deviceId,
          packed,
          source: 'live',
          sampleTsMs: ts,
          replaceId: s.storedId,
        );
        dataChanged();
      }
    } catch (e) {
      s.dirty = true;
      dc.log('[live] store live HR: $e');
      unawaited(repo.log('warn', 'store live HR: $e'));
    } finally {
      _flushing = false;
    }
  }

  @override
  void dispose() {
    dc.removeListener(_onDevice);
    _flush?.cancel();
    super.dispose();
  }
}
