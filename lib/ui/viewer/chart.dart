import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../data/repository.dart';
import 'format.dart';

/// Which value of a [StatBucket] a line shows.
enum StatField { mean, min, max, extra }

double? statValue(StatBucket b, StatField f) => switch (f) {
  StatField.mean => b.mean,
  StatField.min => b.min,
  StatField.max => b.max,
  StatField.extra => b.extra,
};

/// Time-label spacing (hours) so that at most eight labels span
/// [visibleHours]: 5 min steps when zoomed into a few minutes, up to 10 days
/// on a month.
double chartLabelInterval(double visibleHours) {
  const steps = [
    5 / 60,
    10 / 60,
    15 / 60,
    0.5,
    1.0,
    2.0,
    3.0,
    6.0,
    12.0,
    24.0,
    48.0,
    120.0,
    240.0,
  ];
  for (final s in steps) {
    if (visibleHours / s <= 8) return s;
  }
  return steps.last;
}

/// A time-series line chart over [fromMs, toMs). X is hours since the local
/// midnight before [fromMs], so grid lines and time labels fall on round
/// clock times whatever minute the window starts at.
/// Buckets further apart than two bucket widths break the line (data gaps).
///
/// Unless [sparkline], the chart can be zoomed along the time axis with a
/// two-finger pinch and panned with a two-finger drag; one finger is left to
/// the surrounding list. The time labels get denser as the view narrows, and
/// a "fit" button appears while zoomed.
class StatChart extends StatefulWidget {
  const StatChart({
    super.key,
    required this.buckets,
    required this.fromMs,
    required this.toMs,
    required this.bucketMs,
    this.field = StatField.mean,
    this.band = false,
    this.unit = '',
    this.height = 220,
    this.color,
    this.sparkline = false,
    this.viewKey,
  });

  final List<StatBucket> buckets;
  final int fromMs;
  final int toMs;
  final int bucketMs;
  final StatField field;

  /// Draw the min–max range behind the line (HR).
  final bool band;
  final String unit;
  final double height;
  final Color? color;

  /// No axes, no grid, no touch, no zoom: for the dashboard.
  final bool sparkline;

  /// Identifies the view for the purpose of keeping a zoom. When given, the
  /// zoom resets only when this changes; when null, whenever the window
  /// ([fromMs], [toMs]) does. A window that follows the present moves every
  /// minute and passes a key that does not.
  final Object? viewKey;

  /// Furthest the time axis can be zoomed in (24× = one hour of a day).
  static const maxZoom = 24.0;

  @override
  State<StatChart> createState() => _StatChartState();
}

class _StatChartState extends State<StatChart> {
  final _zoom = TransformationController();
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(StatChart old) {
    super.didUpdateWidget(old);
    // A new window (range or prev/next) starts unzoomed.
    final changed = widget.viewKey != null || old.viewKey != null
        ? old.viewKey != widget.viewKey
        : old.fromMs != widget.fromMs || old.toMs != widget.toMs;
    if (changed) {
      _zoom.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _onZoom() {
    final s = _zoom.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.01) setState(() => _scale = s);
  }

  List<StatBucket> get buckets => widget.buckets;
  int get fromMs => widget.fromMs;
  int get toMs => widget.toMs;
  int get bucketMs => widget.bucketMs;
  StatField get field => widget.field;
  bool get band => widget.band;
  bool get sparkline => widget.sparkline;

  /// Local midnight before the window: x = 0.
  int get _originMs {
    final t = DateTime.fromMillisecondsSinceEpoch(fromMs);
    return DateTime(t.year, t.month, t.day).millisecondsSinceEpoch;
  }

  double _x(int ms) => (ms - _originMs) / 3600000;
  int _ms(double x) => _originMs + (x * 3600000).round();

  List<List<FlSpot>> _segments(StatField f) {
    final out = <List<FlSpot>>[];
    var cur = <FlSpot>[];
    int? prev;
    for (final b in buckets) {
      final v = statValue(b, f);
      if (v == null) continue;
      if (prev != null && b.startMs - prev > 2 * bucketMs && cur.isNotEmpty) {
        out.add(cur);
        cur = <FlSpot>[];
      }
      cur.add(FlSpot(_x(b.startMs), v));
      prev = b.startMs;
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lineColor = widget.color ?? scheme.primary;
    final height = widget.height;
    final unit = widget.unit;
    final hours = (toMs - fromMs) / 3600000;
    final mainSegs = _segments(field);
    if (mainSegs.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No data',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final b in buckets) {
      final vs = band
          ? [b.min, b.max]
          : [statValue(b, field)].whereType<double>();
      for (final v in vs) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (hi - lo < 1) {
      hi += 1;
      lo -= 1;
    }
    final pad = (hi - lo) * 0.08;

    final bars = <LineChartBarData>[];
    final between = <BetweenBarsData>[];
    if (band) {
      for (final seg in _segments(StatField.min)) {
        final maxSeg = _segments(StatField.max)
            .firstWhere((s) => s.first.x == seg.first.x, orElse: () => seg);
        final i = bars.length;
        bars.add(_bar(seg, lineColor.withValues(alpha: 0), 0));
        bars.add(_bar(maxSeg, lineColor.withValues(alpha: 0), 0));
        between.add(
          BetweenBarsData(
            fromIndex: i,
            toIndex: i + 1,
            color: lineColor.withValues(alpha: 0.15),
          ),
        );
      }
    }
    for (final seg in mainSegs) {
      bars.add(_bar(seg, lineColor, sparkline ? 1.5 : 2));
    }

    final visibleHours = hours / _scale;
    final labelInterval = chartLabelInterval(visibleHours);
    final textStyle = Theme.of(context).textTheme.labelSmall;

    final chart = LineChart(
      LineChartData(
        minX: _x(fromMs),
        maxX: _x(toMs),
        minY: lo - pad,
        maxY: hi + pad,
        lineBarsData: bars,
        betweenBarsData: between,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: !sparkline,
          drawVerticalLine: true,
          verticalInterval: labelInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 0.5),
          getDrawingVerticalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 0.5),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          show: !sparkline,
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, meta) {
                // The chart edges are padded values; they collide with the
                // nearest round label, so leave them out.
                if (v == meta.min || v == meta.max) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(_num(v), style: textStyle),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: labelInterval,
              // Only the round times: the window edges are arbitrary minutes
              // and would collide with their neighbours.
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: (v, meta) {
                final t = DateTime.fromMillisecondsSinceEpoch(_ms(v));
                final label = visibleHours <= 48
                    ? fmtTime.format(t)
                    : '${t.day}/${t.month}';
                return SideTitleWidget(
                  meta: meta,
                  child: Text(label, style: textStyle),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: !sparkline,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItems: (spots) => [
              for (final s in spots)
                if (s.bar.barWidth > 0)
                  LineTooltipItem(
                    '${_num(s.y)} $unit\n${fmtTimeMs(_ms(s.x))}',
                    TextStyle(color: scheme.onInverseSurface),
                  )
                else
                  null,
            ],
          ),
        ),
      ),
      transformationConfig: sparkline
          ? const FlTransformationConfig()
          : FlTransformationConfig(
              scaleAxis: FlScaleAxis.horizontal,
              maxScale: StatChart.maxZoom,
              // One-finger drags scroll the page; two fingers zoom and pan.
              panEnabled: false,
              transformationController: _zoom,
            ),
      duration: Duration.zero,
    );

    return SizedBox(
      height: height,
      child: sparkline
          ? chart
          : Stack(
              children: [
                Positioned.fill(child: chart),
                if (_scale > 1.01)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: 'Show the whole range',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.fit_screen_outlined, size: 20),
                      onPressed: () => _zoom.value = Matrix4.identity(),
                    ),
                  ),
              ],
            ),
    );
  }

  LineChartBarData _bar(List<FlSpot> spots, Color c, double width) =>
      LineChartBarData(
        spots: spots,
        color: c,
        barWidth: width,
        isCurved: false,
        dotData: const FlDotData(show: false),
      );

  static String _num(double v) =>
      v.abs() >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
