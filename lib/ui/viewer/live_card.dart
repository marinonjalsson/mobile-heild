import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../../state/live_ppi.dart';
import '../widgets/common.dart';

/// The current heart rate with freshness cues, shown on the Graphs page
/// during a live session ("Live" / "Stop" in the action bar; leaving the app
/// ends it with a sync and disconnects).
///
/// With the live PP-interval stream on (app open, connected), the pulse state
/// comes from real beats: the dot lights on each batch with a good beat, the
/// card says whether the pulse is found, unclear or lost, and shows the last
/// minute's HRV. Without it, the fallback is time-based: a value that has not
/// moved for a minute is treated as held (what the Verity Sense does when it
/// loses the pulse).
class LiveHrCard extends StatefulWidget {
  const LiveHrCard(this.dc, {super.key});
  final DeviceController dc;

  @override
  State<LiveHrCard> createState() => _LiveHrCardState();
}

class _LiveHrCardState extends State<LiveHrCard>
    with SingleTickerProviderStateMixin {
  /// Recorded data from the Verity Sense shows normal HR holding one value
  /// for up to ~40 s; frozen (pulse lost) stretches run 60 s and longer.
  static const _weakAfter = Duration(seconds: 60);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  Timer? _tick;
  int _seenBatches = -1;
  HrSample? _seenNotification;
  DateTime? _lastDataAt;
  DateTime? _lastChangeAt;
  int? _lastHr;
  int? _seenBeatBatchMs;

  LivePpiService get _live => appController.livePpi;

  @override
  void initState() {
    super.initState();
    widget.dc.addListener(_onDevice);
    _live.addListener(_onLive);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _onDevice();
  }

  @override
  void dispose() {
    widget.dc.removeListener(_onDevice);
    _live.removeListener(_onLive);
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _flash() {
    _pulse.value = 1;
    _pulse.animateTo(0, curve: Curves.easeOut);
  }

  HrSample? _current() {
    final active = widget.dc.streams[PolarDataType.hr];
    final batch = active?.latest;
    if (batch != null && batch.samples.isNotEmpty) {
      return HrSample.fromMap(batch.samples.last);
    }
    return widget.dc.lastHrNotification;
  }

  void _onDevice() {
    final active = widget.dc.streams[PolarDataType.hr];
    final s = _current();
    if (s == null) return;
    final isNew = active != null
        ? active.batches != _seenBatches
        : !identical(widget.dc.lastHrNotification, _seenNotification);
    if (!isNew) return;
    _seenBatches = active?.batches ?? -1;
    _seenNotification = widget.dc.lastHrNotification;
    final now = DateTime.now();
    _lastDataAt = now;
    if (s.hr != _lastHr) {
      _lastHr = s.hr;
      _lastChangeAt = now;
    }
    // With real beats available the dot follows them, not the HR repeats.
    if (_live.state == PulseState.off) _flash();
    if (mounted) setState(() {});
  }

  void _onLive() {
    final session = _live.session;
    final at = session?.lastBatchMs;
    if (session != null && at != null && at != _seenBeatBatchMs) {
      _seenBeatBatchMs = at;
      if (session.goodBeatsSince(at) > 0) _flash();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dc;
    final sync = appController.sync;
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final s = sync.isLive ? _current() : null;
    final now = DateTime.now();
    final age = _lastDataAt == null ? null : now.difference(_lastDataAt!);
    final unchanged = _lastChangeAt == null
        ? null
        : now.difference(_lastChangeAt!);
    final hasRr = s != null && s.rrAvailable && s.rrsMs.isNotEmpty;

    final pulse = _live.state;
    final beats = pulse != PulseState.off;
    final weak =
        !beats &&
        s != null &&
        unchanged != null &&
        unchanged >= _weakAfter &&
        !hasRr;
    final stale = age != null && age.inSeconds >= 10;
    final bad = beats
        ? pulse == PulseState.poor || pulse == PulseState.lost
        : weak || stale;
    // The HR service reports 0 for a moment when the PPI algorithm takes
    // over; the beats carry their own heart rate, use it meanwhile.
    final beatHr = _live.session?.hr.lastOrNull ?? 0;
    final shownHr = s == null
        ? 0
        : s.hr > 0 || pulse != PulseState.good
        ? s.hr
        : beatHr;

    return Section(
      title: 'Live heart rate',
      trailing: FadeTransition(
        opacity: _pulse,
        child: Icon(Icons.circle, size: 10, color: scheme.primary),
      ),
      children: [
        if (s == null)
          Text(
            dc.isConnected
                ? 'Waiting for the first beat…'
                : dc.connection == PolarConnectionState.connecting
                ? 'Connecting to the sensor…'
                : 'Sensor not reachable',
            style: small,
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$shownHr',
                style: Theme.of(context).textTheme.displayMedium
                    ?.copyWith(color: bad ? scheme.outline : null),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'bpm${s.contactStatusSupported ? (s.contactStatus ? ' · on skin' : ' · no contact') : ''}'
                  '${hasRr ? ' · RR ${s.rrsMs.last} ms' : ''}',
                ),
              ),
            ],
          ),
          Text(
            age == null
                ? 'no update yet'
                : age.inSeconds < 2
                ? 'updated just now'
                : 'updated ${age.inSeconds} s ago',
            style: small?.copyWith(color: stale ? scheme.error : null),
          ),
          if (beats)
            _pulseLine(context, pulse)
          else if (weak)
            _weakLine(context, unchanged),
        ],
      ],
    );
  }

  Widget _pulseLine(BuildContext context, PulseState pulse) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final last = _live.lastBatchAt;
    final ago = last == null ? null : DateTime.now().difference(last).inSeconds;
    final rmssd = _live.rmssdLastMinute;
    final (IconData icon, String text, Color color) = switch (pulse) {
      PulseState.warmingUp => (
        Icons.hourglass_top,
        'Finding the pulse… (the sensor needs about 25 s)',
        scheme.outline,
      ),
      PulseState.good => (
        Icons.favorite,
        'Pulse found · last beats ${ago ?? 0} s ago'
            '${rmssd == null ? '' : ' · HRV ${rmssd.round()} ms'}',
        scheme.primary,
      ),
      PulseState.poor => (
        Icons.vibration,
        'Pulse unclear: movement or a loose strap. The number may be held.',
        scheme.error,
      ),
      PulseState.lost => (
        Icons.heart_broken_outlined,
        'No pulse for ${ago ?? 0} s: tighten the band or move it up the arm. '
            'The number is the sensor repeating its last reading.',
        scheme.error,
      ),
      PulseState.off => (Icons.circle, '', scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: small?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }

  Widget _weakLine(BuildContext context, Duration? unchanged) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.signal_cellular_nodata, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Weak signal: same value for ${unchanged?.inSeconds ?? 0} s. '
              'Samples still arrive, but the sensor repeats its last '
              'reading when it cannot find the pulse. Tighten the band '
              'or move it up the arm.',
              style: small?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
