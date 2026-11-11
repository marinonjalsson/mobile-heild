import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/ui/viewer/graph_window.dart';

StatBucket bucket(DateTime start) => StatBucket(
  startMs: start.millisecondsSinceEpoch,
  n: 60,
  mean: 60,
  min: 55,
  max: 65,
);

void main() {
  final now = DateTime(2026, 11, 11, 17, 2, 40);

  test('each range reaches back from now, not from a calendar boundary', () {
    GraphWindow w(GraphRange r) => GraphWindow.at(r, now: now);
    // The minute being recorded (17:02) is inside the window.
    expect(w(GraphRange.hour).to, DateTime(2026, 11, 11, 17, 3));
    expect(w(GraphRange.hour).from, DateTime(2026, 11, 11, 16, 3));
    expect(w(GraphRange.sixHours).from, DateTime(2026, 11, 11, 11, 3));
    expect(w(GraphRange.day).from, DateTime(2026, 11, 10, 17, 3));
    expect(w(GraphRange.week).from, DateTime(2026, 11, 4, 17, 3));
    expect(w(GraphRange.month).from, DateTime(2026, 10, 11, 17, 3));
  });

  test('a window in the past ends where it was put', () {
    final end = DateTime(2026, 11, 11, 16, 3);
    final w = GraphWindow.at(GraphRange.hour, end: end, now: now);
    expect(w.from, DateTime(2026, 11, 11, 15, 3));
    expect(w.to, end);
    expect(w.axisTo, end);
  });

  test('stepping back and forward by a range returns to the same window', () {
    for (final r in GraphRange.values) {
      final to = GraphWindow.at(r, now: now).to;
      expect(rangeBack(rangeBack(to, r), r, -1), to, reason: '$r');
    }
  });

  test('the axis ends at the newest point', () {
    final w = GraphWindow.at(GraphRange.hour, now: now);
    final shown = w.trimmedTo([
      bucket(DateTime(2026, 11, 11, 16, 10)),
      bucket(DateTime(2026, 11, 11, 16, 49)),
    ], 60000);
    expect(shown.from, w.from);
    expect(shown.to, w.to); // the query window is unchanged
    expect(shown.axisTo, DateTime(2026, 11, 11, 16, 50));
  });

  test('nothing in the window, or data up to now, leaves the axis alone', () {
    final w = GraphWindow.at(GraphRange.hour, now: now);
    expect(w.trimmedTo(const [], 60000).axisTo, w.to);
    expect(
      w.trimmedTo([bucket(DateTime(2026, 11, 11, 17, 2))], 60000).axisTo,
      w.to,
    );
  });

  test('coarse buckets do not push the axis past the window', () {
    // Week view: ten-minute buckets aligned to the window start.
    final w = GraphWindow.at(GraphRange.week, now: now);
    final last = w.to.subtract(const Duration(minutes: 3));
    expect(w.trimmedTo([bucket(last)], 600000).axisTo, w.to);
  });
}
