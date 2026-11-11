import '../../data/repository.dart';

/// The time selector of the Graphs page.
enum GraphRange { hour, sixHours, day, week, month }

/// [t] moved back by [n] ranges (forward when [n] is negative). Days, weeks
/// and months step on the calendar, so the clock time stays the same across a
/// daylight-saving change and a month is the same day one month earlier.
DateTime rangeBack(DateTime t, GraphRange r, [int n = 1]) => switch (r) {
  GraphRange.hour => t.subtract(Duration(hours: n)),
  GraphRange.sixHours => t.subtract(Duration(hours: 6 * n)),
  GraphRange.day => DateTime(t.year, t.month, t.day - n, t.hour, t.minute),
  GraphRange.week => DateTime(t.year, t.month, t.day - 7 * n, t.hour, t.minute),
  GraphRange.month => DateTime(t.year, t.month - n, t.day, t.hour, t.minute),
};

/// What the graphs show: data is queried over [from, to), the time axis runs
/// from [from] to [axisTo].
class GraphWindow {
  const GraphWindow(this.from, this.to, this.axisTo);

  final DateTime from;
  final DateTime to;

  /// Where the axis ends. Equal to [to], except while following the present
  /// (see [GraphWindow.at]), where [trimmedTo] pulls it in to the newest point.
  final DateTime axisTo;

  int get fromMs => from.millisecondsSinceEpoch;
  int get toMs => to.millisecondsSinceEpoch;

  /// The window one [range] long that ends at [end], or, when [end] is null,
  /// at [now]: the selector means "the last hour / six hours / day / week /
  /// month", not the calendar hour or day that [now] happens to fall in.
  /// [now] is taken up to the end of its minute, so the minute being recorded
  /// is inside the window.
  factory GraphWindow.at(
    GraphRange range, {
    DateTime? end,
    required DateTime now,
  }) {
    final to =
        end ?? DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    return GraphWindow(rangeBack(to, range), to, to);
  }

  /// The same window with the axis ending at the newest of [buckets] instead
  /// of at [to], so the time since the last sync is not an empty stretch at
  /// the right edge. Unchanged when there is nothing in the window.
  GraphWindow trimmedTo(List<StatBucket> buckets, int bucketMs) {
    if (buckets.isEmpty) return this;
    final newest = buckets.last.startMs + bucketMs;
    if (newest >= toMs || newest <= fromMs) return this;
    return GraphWindow(from, to, DateTime.fromMillisecondsSinceEpoch(newest));
  }
}
