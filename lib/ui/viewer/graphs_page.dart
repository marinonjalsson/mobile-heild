import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../../state/sync_service.dart';
import '../widgets/common.dart';
import 'chart.dart';
import 'format.dart';
import 'graph_window.dart';
import 'live_card.dart';

/// Minute-stat graphs per type over the last hour, six hours, day, week or
/// month: the window ends at the present and reaches one range back, and the
/// axis stops at the newest point. Prev/next step by one window (a window in
/// the past is shown whole); the charts themselves pinch-zoom.
/// "Live" in the type row streams the shown type (heart rate, pulse intervals
/// or movement) and shows it in a card above the charts.
class GraphsPage extends StatefulWidget {
  const GraphsPage({super.key});

  @override
  State<GraphsPage> createState() => _GraphsPageState();
}

class _GraphsPageState extends State<GraphsPage> {
  /// "Disconnected" stays on the status line this long after a sync ends.
  static const _endingFor = Duration(seconds: 3);

  bool _wasActive = false;
  bool _ending = false;
  Timer? _endTimer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    appController.sync.addListener(_onSync);
    // Coming back to the app after a while: "the last hour" has moved on.
    // No timer for this: the engine also runs headless, and a tick a minute
    // there would be a wake-up a minute for nobody.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted && _end == null) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    appController.sync.removeListener(_onSync);
    _endTimer?.cancel();
    super.dispose();
  }

  /// A sync or connect in progress (the status line is shown, Sync disabled).
  static bool _active(SyncService sync, DeviceController dc) =>
      sync.isRunning ||
      sync.phase == SyncPhase.connecting ||
      dc.connection == PolarConnectionState.connecting;

  void _onSync() {
    final active = _active(appController.sync, appController.device);
    if (_wasActive && !active) {
      _endTimer?.cancel();
      _ending = true;
      _endTimer = Timer(_endingFor, () {
        if (mounted) setState(() => _ending = false);
      });
    }
    _wasActive = active;
  }

  PolarDataType _type = PolarDataType.hr;
  GraphRange _range = GraphRange.day;

  /// Where the window ends, or null to follow the present ("Now").
  DateTime? _end;

  int get _bucketMs => switch (_range) {
    GraphRange.hour || GraphRange.sixHours || GraphRange.day => 60000,
    GraphRange.week => 600000,
    GraphRange.month => 3600000,
  };

  void _shift(int dir) {
    final now = DateTime.now();
    final end = rangeBack(
      GraphWindow.at(_range, end: _end, now: now).to,
      _range,
      -dir,
    );
    // Stepping forward into the present goes back to following it.
    setState(() => _end = end.isBefore(now) ? end : null);
  }

  static String _title(GraphRange range, GraphWindow w) {
    final from = w.from;
    final to = w.axisTo;
    final sameDay =
        from.year == to.year && from.month == to.month && from.day == to.day;
    return switch (range) {
      GraphRange.hour || GraphRange.sixHours when sameDay =>
        '${fmtDate.format(from)} · ${fmtTime.format(from)} – ${fmtTime.format(to)}',
      GraphRange.hour || GraphRange.sixHours || GraphRange.day =>
        '${fmtDateTime.format(from)} – ${fmtDateTime.format(to)}',
      GraphRange.week ||
      GraphRange.month => '${fmtDate.format(from)} – ${fmtDate.format(to)}',
    };
  }

  /// Segment label per type (short enough for three in a row).
  static String _short(PolarDataType t) => switch (t) {
    PolarDataType.hr => 'Heart rate',
    PolarDataType.ppi => 'HRV',
    PolarDataType.acc => 'Movement',
    _ => t.label,
  };

  /// Header per type (the app bar title).
  static String _header(PolarDataType t) => switch (t) {
    PolarDataType.hr => 'Heart rate',
    PolarDataType.ppi => 'Pulse intervals · HRV',
    PolarDataType.acc => 'Movement',
    _ => t.label,
  };

  // The stats query is cached per (type, window, data version) so that
  // unrelated rebuilds (sync progress ticks) do not re-query, and the chart
  // keeps showing the old buckets while the new ones load.
  Object? _futureKey;
  Future<List<StatBucket>>? _future;

  /// The buckets of the window on screen, once loaded: the date row shows
  /// where the axis ends, which depends on them.
  List<StatBucket> _buckets = const [];

  /// While following the present the axis ends at the newest point; a window
  /// in the past is shown whole.
  GraphWindow _shown(GraphWindow w, List<StatBucket> b) =>
      _end == null ? w.trimmedTo(b, _bucketMs) : w;

  Future<List<StatBucket>> _stats(int fromMs, int toMs, int version) {
    final key = (_type, fromMs, toMs, _bucketMs, version);
    if (key != _futureKey) {
      _futureKey = key;
      _buckets = const [];
      final future = _future = appController.repo.stats(
        _type,
        fromMs,
        toMs,
        bucketMs: _bucketMs,
        alignMs: fromMs,
      );
      future.then((b) {
        if (mounted && identical(future, _future)) {
          setState(() => _buckets = b);
        }
      });
    }
    return _future!;
  }

  @override
  Widget build(BuildContext context) {
    final sync = appController.sync;
    final dc = appController.device;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, dc]),
      builder: (context, _) {
        // Inside the builder: while following the present the window moves,
        // and every sync notification is a chance to move it.
        final window = GraphWindow.at(_range, end: _end, now: DateTime.now());
        final fromMs = window.fromMs;
        final toMs = window.toMs;
        final busy = _active(sync, dc) || _ending;
        final connecting = !sync.isRunning && _active(sync, dc);
        final status = _ending && !_active(sync, dc)
            ? 'Disconnected'
            : connecting
            ? 'Connecting…'
            : sync.detail;
        return Scaffold(
          appBar: AppBar(
            title: Text(_header(_type)),
            bottom: busy
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(28),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: _ending && !_active(sync, dc)
                              ? 1
                              : sync.progressPercent == null
                              ? null
                              : sync.progressPercent! / 100,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (sync.isLive && _type == sync.liveType) LiveCard(dc, _type),
              FutureBuilder<List<StatBucket>>(
                future: _stats(fromMs, toMs, sync.dataVersion),
                builder: (context, snap) {
                  final b = snap.data;
                  if (b == null) return const LinearProgressIndicator();
                  final shown = _shown(window, b);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final panel in _panels(context, _type))
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Text(
                                    panel.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                StatChart(
                                  buckets: b,
                                  fromMs: fromMs,
                                  toMs: shown.axisTo.millisecondsSinceEpoch,
                                  bucketMs: _bucketMs,
                                  // The window slides a minute at a time
                                  // while following the present; that must
                                  // not throw away a pinch-zoom.
                                  viewKey: (_type, _range, _end),
                                  field: panel.field,
                                  band: panel.band,
                                  unit: panel.unit,
                                  color: panel.color,
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          '${b.length} buckets · ${b.fold<int>(0, (s, x) => s + x.n)} samples'
                          '${sync.lastSyncAt == null ? '' : ' · synced ${fmtAgo(sync.lastSyncAt)}'}'
                          ' · pinch with two fingers to zoom the time axis',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          // The controls sit above the app's navigation bar and look like
          // it: full-width rows, a pill under the selected item, no icons.
          bottomNavigationBar: Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The window: < date/time >, styled like the rows below.
                  _DateRow(
                    title: _title(_range, _shown(window, _buckets)),
                    onPrev: () => _shift(-1),
                    onNext: _end == null ? null : () => _shift(1),
                  ),
                  // Action bar: the time window group, then the commands.
                  _BarRow<GraphRange>(
                    items: const [
                      (GraphRange.hour, '1 h'),
                      (GraphRange.sixHours, '6 h'),
                      (GraphRange.day, 'Day'),
                      (GraphRange.week, 'Week'),
                      (GraphRange.month, 'Month'),
                    ],
                    selected: _range,
                    onSelected: (r) => setState(() => _range = r),
                    actions: [
                      _BarAction(
                        'Now',
                        _end == null ? null : () => setState(() => _end = null),
                      ),
                      _BarAction(
                        'Sync',
                        busy || !appController.settings.isPaired
                            ? null
                            : () => runAction(
                                context,
                                () => dc.isConnected
                                    ? sync.syncNow(reason: 'manual')
                                    : sync.connectAndSync(reason: 'manual'),
                              ),
                      ),
                    ],
                  ),
                  // Type row: the graph, and Live for that graph's stream
                  // (heart rate or pulse intervals; movement cannot be
                  // streamed). While live, picking another graph switches
                  // the stream.
                  _BarRow<PolarDataType>(
                    items: [for (final t in viewerTypes) (t, _short(t))],
                    selected: _type,
                    onSelected: (t) {
                      setState(() => _type = t);
                      if (sync.isLive && SyncService.liveTypes.contains(t)) {
                        runAction(context, () => sync.setLiveType(t));
                      }
                    },
                    actions: [
                      _BarAction(
                        sync.isLive ? 'Stop' : 'Live',
                        !sync.isLive &&
                                (busy ||
                                    !appController.settings.isPaired ||
                                    !SyncService.liveTypes.contains(_type))
                            ? null
                            : () => runAction(
                                context,
                                () => sync.isLive
                                    ? sync.stopLive()
                                    : sync.startLive(_type),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<_Panel> _panels(BuildContext context, PolarDataType t) {
    final scheme = Theme.of(context).colorScheme;
    return switch (t) {
      PolarDataType.hr => [
        _Panel(
          'Heart rate (bpm) · mean with min–max band',
          StatField.mean,
          band: true,
          unit: 'bpm',
        ),
      ],
      PolarDataType.ppi => [
        _Panel('PP interval (ms) · mean', StatField.mean, unit: 'ms'),
        _Panel(
          'HRV · RMSSD (ms)',
          StatField.extra,
          unit: 'ms',
          color: scheme.tertiary,
        ),
      ],
      PolarDataType.acc => [
        _Panel(
          'Movement · std of |a| (mG)',
          StatField.extra,
          unit: 'mG',
          color: scheme.tertiary,
        ),
        _Panel('|a| mean (mG)', StatField.mean, unit: 'mG'),
      ],
      _ => const [],
    };
  }
}

class _Panel {
  const _Panel(
    this.title,
    this.field, {
    this.band = false,
    this.unit = '',
    this.color,
  });
  final String title;
  final StatField field;
  final bool band;
  final String unit;
  final Color? color;
}

/// A command in a [_BarRow]: text, tap, greyed when [onTap] is null.
class _BarAction {
  const _BarAction(this.label, this.onTap);
  final String label;
  final VoidCallback? onTap;
}

/// One selector row in the style of the navigation bar: equal-width text
/// items, the selected one on a pill. [actions] are commands grouped at
/// the end behind a thin divider.
class _BarRow<T> extends StatelessWidget {
  const _BarRow({
    required this.items,
    required this.selected,
    required this.onSelected,
    this.actions = const [],
  });

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final List<_BarAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Seven or eight columns on a phone need the smaller label.
    final dense = items.length + actions.length > 5;
    final text = dense
        ? Theme.of(context).textTheme.labelMedium
        : Theme.of(context).textTheme.labelLarge;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          for (final (value, label) in items)
            Expanded(
              child: InkWell(
                onTap: () => onSelected(value),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: EdgeInsets.symmetric(
                      horizontal: dense ? 3 : 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: value == selected
                          ? scheme.secondaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text?.copyWith(
                        color: value == selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: value == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (actions.isNotEmpty)
            VerticalDivider(
              width: 4,
              indent: 12,
              endIndent: 12,
              color: scheme.outlineVariant,
            ),
          for (final a in actions)
            SizedBox(
              width: dense ? 42 : 52,
              child: InkWell(
                onTap: a.onTap,
                child: Center(
                  child: Text(
                    a.label,
                    maxLines: 1,
                    style: text?.copyWith(
                      color: a.onTap == null ? scheme.outline : scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The < date/time > row in the style of [_BarRow]: chevrons as commands at
/// the action width, the window title in the row label style.
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.title,
    required this.onPrev,
    required this.onNext,
  });

  final String title;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelLarge;
    Widget chevron(IconData icon, VoidCallback? onTap) => SizedBox(
      width: 58,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Icon(
            icon,
            size: 22,
            color: onTap == null ? scheme.outline : scheme.primary,
          ),
        ),
      ),
    );
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          chevron(Icons.chevron_left, onPrev),
          Expanded(
            child: Center(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          chevron(Icons.chevron_right, onNext),
        ],
      ),
    );
  }
}
