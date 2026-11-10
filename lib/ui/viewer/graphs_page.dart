import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../widgets/common.dart';
import 'chart.dart';
import 'format.dart';

enum _Range { hour, sixHours, day, week, month }

/// Minute-stat graphs per type over an hour, six hours, a day, a week or a
/// month. Prev/next step by one window; the charts themselves pinch-zoom.
class GraphsPage extends StatefulWidget {
  const GraphsPage({super.key});

  @override
  State<GraphsPage> createState() => _GraphsPageState();
}

class _GraphsPageState extends State<GraphsPage> {
  PolarDataType _type = PolarDataType.hr;
  _Range _range = _Range.day;

  /// Any instant inside the shown window; [_window] aligns it to the range.
  DateTime _anchor = DateTime.now();

  (DateTime from, DateTime to) get _window {
    final a = _anchor;
    final day = DateTime(a.year, a.month, a.day);
    return switch (_range) {
      _Range.hour => (
        DateTime(a.year, a.month, a.day, a.hour),
        DateTime(a.year, a.month, a.day, a.hour + 1),
      ),
      _Range.sixHours => (
        DateTime(a.year, a.month, a.day, a.hour - a.hour % 6),
        DateTime(a.year, a.month, a.day, a.hour - a.hour % 6 + 6),
      ),
      _Range.day => (day, DateTime(a.year, a.month, a.day + 1)),
      _Range.week => (
        day.subtract(Duration(days: day.weekday - 1)),
        DateTime(a.year, a.month, a.day - (day.weekday - 1) + 7),
      ),
      _Range.month => (
        DateTime(a.year, a.month),
        DateTime(a.year, a.month + 1),
      ),
    };
  }

  int get _bucketMs => switch (_range) {
    _Range.hour || _Range.sixHours || _Range.day => 60000,
    _Range.week => 600000,
    _Range.month => 3600000,
  };

  void _shift(int dir) {
    final (from, _) = _window;
    setState(() {
      // Step from the window start so DST days and month lengths work out.
      _anchor = switch (_range) {
        _Range.hour => DateTime(
          from.year,
          from.month,
          from.day,
          from.hour + dir,
          30,
        ),
        _Range.sixHours => DateTime(
          from.year,
          from.month,
          from.day,
          from.hour + 6 * dir,
          30,
        ),
        _Range.day => DateTime(from.year, from.month, from.day + dir, 12),
        _Range.week => DateTime(from.year, from.month, from.day + 7 * dir, 12),
        _Range.month => DateTime(from.year, from.month + dir, 1, 12),
      };
    });
  }

  String get _title {
    final (from, to) = _window;
    return switch (_range) {
      _Range.hour || _Range.sixHours =>
        '${fmtDate.format(from)} · ${fmtTime.format(from)} – ${fmtTime.format(to)}',
      _Range.day => fmtDateLong.format(from),
      _Range.week =>
        '${fmtDate.format(from)} – ${fmtDate.format(to.subtract(const Duration(days: 1)))}',
      _Range.month => '${_monthName(from.month)} ${from.year}',
    };
  }

  static String _monthName(int m) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][m - 1];

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

  Future<List<StatBucket>> _stats(int fromMs, int toMs, int version) {
    final key = (_type, fromMs, toMs, _bucketMs, version);
    if (key != _futureKey) {
      _futureKey = key;
      _future = appController.repo.stats(
        _type,
        fromMs,
        toMs,
        bucketMs: _bucketMs,
        alignMs: fromMs,
      );
    }
    return _future!;
  }

  @override
  Widget build(BuildContext context) {
    final (from, to) = _window;
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;
    final sync = appController.sync;
    final dc = appController.device;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final busy = sync.isRunning;
        final connecting = dc.connection == PolarConnectionState.connecting;
        return Scaffold(
          appBar: AppBar(
            title: Text(_header(_type)),
            actions: [
              TextButton(
                onPressed: () => setState(() => _anchor = DateTime.now()),
                child: const Text('Now'),
              ),
              IconButton(
                tooltip: 'Sync now',
                onPressed:
                    busy || connecting || !appController.settings.isPaired
                    ? null
                    : () => runAction(
                        context,
                        () => dc.isConnected
                            ? sync.syncNow(reason: 'manual')
                            : sync.connectAndSync(reason: 'manual'),
                      ),
                icon: const Icon(Icons.sync),
              ),
            ],
            bottom: busy || connecting
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(28),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: sync.progressPercent == null
                              ? null
                              : sync.progressPercent! / 100,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              sync.detail,
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
              Row(
                children: [
                  IconButton(
                    onPressed: () => _shift(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      _title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: toMs > DateTime.now().millisecondsSinceEpoch
                        ? null
                        : () => _shift(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              FutureBuilder<List<StatBucket>>(
                future: _stats(fromMs, toMs, sync.dataVersion),
                builder: (context, snap) {
                  final b = snap.data;
                  if (b == null) return const LinearProgressIndicator();
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
                                  toMs: toMs,
                                  bucketMs: _bucketMs,
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
                  _BarRow<_Range>(
                    items: const [
                      (_Range.hour, '1 h'),
                      (_Range.sixHours, '6 h'),
                      (_Range.day, 'Day'),
                      (_Range.week, 'Week'),
                      (_Range.month, 'Month'),
                    ],
                    selected: _range,
                    onSelected: (r) => setState(() => _range = r),
                  ),
                  _BarRow<PolarDataType>(
                    items: [for (final t in viewerTypes) (t, _short(t))],
                    selected: _type,
                    onSelected: (t) => setState(() => _type = t),
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
        _Panel(
          'HRV · RMSSD (ms)',
          StatField.extra,
          unit: 'ms',
          color: scheme.tertiary,
        ),
        _Panel('PP interval (ms) · mean', StatField.mean, unit: 'ms'),
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

/// One selector row in the style of the navigation bar: equal-width text
/// items, the selected one on a pill.
class _BarRow<T> extends StatelessWidget {
  const _BarRow({
    required this.items,
    required this.selected,
    required this.onSelected,
  });

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelLarge;
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
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
        ],
      ),
    );
  }
}
