import 'package:flutter_test/flutter_test.dart';
import 'package:heild/ui/viewer/chart.dart';

void main() {
  test('time labels keep to at most eight per visible span', () {
    expect(chartLabelInterval(24), 3); // day, unzoomed
    expect(chartLabelInterval(24 / 24), 10 / 60); // day zoomed to one hour
    expect(chartLabelInterval(6), 1);
    expect(chartLabelInterval(1), 10 / 60);
    expect(chartLabelInterval(0.25), 5 / 60);
    expect(chartLabelInterval(24 * 7), 24);
    expect(chartLabelInterval(24 * 31), 120);
    for (final h in [0.1, 0.5, 1, 3, 6, 12, 24, 100, 24 * 7, 24 * 31]) {
      expect(h / chartLabelInterval(h.toDouble()), lessThanOrEqualTo(8));
    }
  });
}
