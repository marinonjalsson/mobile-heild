import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
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

  @override
  Widget build(BuildContext context) {
    final (from, to) = _window;
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graphs'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _anchor = DateTime.now()),
            child: const Text('Now'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: appController.sync,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final t in viewerTypes)
                  ChoiceChip(
                    label: Text(t.label),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<_Range>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              segments: const [
                ButtonSegment(value: _Range.hour, label: Text('1 h')),
                ButtonSegment(value: _Range.sixHours, label: Text('6 h')),
                ButtonSegment(value: _Range.day, label: Text('Day')),
                ButtonSegment(value: _Range.week, label: Text('Week')),
                ButtonSegment(value: _Range.month, label: Text('Month')),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
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
              key: ValueKey((
                _type,
                fromMs,
                toMs,
                appController.sync.lastSyncAt,
              )),
              future: appController.repo.stats(
                _type,
                fromMs,
                toMs,
                bucketMs: _bucketMs,
                alignMs: fromMs,
              ),
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
                                  style: Theme.of(context).textTheme.titleSmall,
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
      ),
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
