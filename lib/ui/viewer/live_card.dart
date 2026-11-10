import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../../state/live_ppi.dart';
import '../widgets/common.dart';

/// The live card of the Graphs page: the stream that belongs to the shown
/// graph ("Live" / "Stop" in the type row; leaving the app ends the session
/// with a sync and disconnects).
class LiveCard extends StatelessWidget {
  const LiveCard(this.dc, this.type, {super.key});
  final DeviceController dc;
  final PolarDataType type;

  @override
  Widget build(BuildContext context) =>
      type == PolarDataType.ppi ? LivePpiCard(dc) : LiveHrCard(dc);
}

/// The current heart rate with freshness cues (the Heart rate graph live).
///
/// With the live PP-interval stream on (the HRV graph), the pulse state
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
            PulseLine(_live)
          else if (weak)
            _weakLine(context, unchanged),
        ],
      ],
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

/// One line on the pulse as the live PP intervals see it: found, unclear,
/// lost or still warming up, with the last minute's HRV when found.
class PulseLine extends StatelessWidget {
  const PulseLine(this.live, {this.showHrv = true, super.key});
  final LivePpiService live;

  /// Append the last minute's HRV when the pulse is found.
  final bool showHrv;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final pulse = live.state;
    final last = live.lastBatchAt;
    final ago = last == null ? null : DateTime.now().difference(last).inSeconds;
    final rmssd = showHrv ? live.rmssdLastMinute : null;
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
}

/// Live pulse intervals (the HRV graph live): heart rate from the beats, the
/// last interval, HRV over the last minute and the pulse state.
class LivePpiCard extends StatefulWidget {
  const LivePpiCard(this.dc, {super.key});
  final DeviceController dc;

  @override
  State<LivePpiCard> createState() => _LivePpiCardState();
}

class _LivePpiCardState extends State<LivePpiCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  Timer? _tick;
  int? _seenBeatBatchMs;

  LivePpiService get _live => appController.livePpi;

  @override
  void initState() {
    super.initState();
    _live.addListener(_onLive);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _live.removeListener(_onLive);
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _onLive() {
    final session = _live.session;
    final at = session?.lastBatchMs;
    if (session != null && at != null && at != _seenBeatBatchMs) {
      _seenBeatBatchMs = at;
      if (session.goodBeatsSince(at) > 0) {
        _pulse.value = 1;
        _pulse.animateTo(0, curve: Curves.easeOut);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dc = widget.dc;
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final session = _live.session;
    final pulse = _live.state;
    final hasBeats = session != null && session.length > 0;
    final bad = pulse == PulseState.poor || pulse == PulseState.lost;
    final rmssd = _live.rmssdLastMinute;
    return Section(
      title: 'Live pulse intervals',
      trailing: FadeTransition(
        opacity: _pulse,
        child: Icon(Icons.circle, size: 10, color: scheme.primary),
      ),
      children: [
        if (!hasBeats)
          Text(
            _live.lastError != null
                ? 'Pulse intervals not available: ${_live.lastError}'
                : _live.streaming
                ? 'Waiting for the first beats… (the sensor needs about 25 s)'
                : dc.isConnected
                ? 'Starting the pulse-interval stream…'
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
                '${session.hr.last}',
                style: Theme.of(context).textTheme.displayMedium
                    ?.copyWith(color: bad ? scheme.outline : null),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'bpm · PP ${session.ppi.last} ms'
                  '${rmssd == null ? '' : ' · HRV ${rmssd.round()} ms'}',
                ),
              ),
            ],
          ),
          Text('${session.length} beats this session', style: small),
          PulseLine(_live, showHrv: false),
        ],
      ],
    );
  }
}
