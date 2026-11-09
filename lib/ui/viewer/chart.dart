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

/// A time-series line chart over [fromMs, toMs). X is hours since [fromMs].
/// Buckets further apart than two bucket widths break the line (data gaps).
class StatChart extends StatelessWidget {
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

  /// No axes, no grid, no touch: for the dashboard.
  final bool sparkline;

  double _x(int ms) => (ms - fromMs) / 3600000;

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
    final lineColor = color ?? scheme.primary;
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

    final labelInterval = hours <= 24
        ? 3.0
        : hours <= 24 * 7
        ? 24.0
        : 24.0 * 5;
    final textStyle = Theme.of(context).textTheme.labelSmall;

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: hours,
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
                getTitlesWidget: (v, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(_num(v), style: textStyle),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: labelInterval,
                getTitlesWidget: (v, meta) {
                  if (v >= hours) return const SizedBox.shrink();
                  final t = DateTime.fromMillisecondsSinceEpoch(
                    fromMs + (v * 3600000).round(),
                  );
                  final label = hours <= 24
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
                      '${_num(s.y)} $unit\n${fmtTimeMs(fromMs + (s.x * 3600000).round())}',
                      TextStyle(color: scheme.onInverseSurface),
                    )
                  else
                    null,
              ],
            ),
          ),
        ),
        duration: Duration.zero,
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
