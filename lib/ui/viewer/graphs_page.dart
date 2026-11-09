import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
import 'chart.dart';
import 'format.dart';

enum _Range { day, week, month }

/// Minute-stat graphs per type over a day, week or month.
class GraphsPage extends StatefulWidget {
  const GraphsPage({super.key});

  @override
  State<GraphsPage> createState() => _GraphsPageState();
}

class _GraphsPageState extends State<GraphsPage> {
  PolarDataType _type = PolarDataType.hr;
  _Range _range = _Range.day;
  DateTime _anchor = _today();

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  (DateTime from, DateTime to) get _window => switch (_range) {
    _Range.day => (_anchor, _anchor.add(const Duration(days: 1))),
    _Range.week => (
      _anchor.subtract(Duration(days: _anchor.weekday - 1)),
      _anchor
          .subtract(Duration(days: _anchor.weekday - 1))
          .add(const Duration(days: 7)),
    ),
    _Range.month => (
      DateTime(_anchor.year, _anchor.month),
      DateTime(_anchor.year, _anchor.month + 1),
    ),
  };

  int get _bucketMs => switch (_range) {
    _Range.day => 60000,
    _Range.week => 600000,
    _Range.month => 3600000,
  };

  void _shift(int dir) {
    setState(() {
      _anchor = switch (_range) {
        _Range.day => _anchor.add(Duration(days: dir)),
        _Range.week => _anchor.add(Duration(days: 7 * dir)),
        _Range.month => DateTime(_anchor.year, _anchor.month + dir),
      };
    });
  }

  String get _title {
    final (from, to) = _window;
    return switch (_range) {
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
            onPressed: () => setState(() => _anchor = _today()),
            child: const Text('Today'),
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
              segments: const [
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
                        '${b.length} buckets · ${b.fold<int>(0, (s, x) => s + x.n)} samples',
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
