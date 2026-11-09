import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/polar_time.dart';

void main() {
  Duration utc(int _) => Duration.zero;
  Duration plusTwo(int _) => const Duration(hours: 2);

  test('Polar epoch maps to 2000-01-01 UTC', () {
    expect(polarNsToUnixMs(0, zoneOffsetFor: utc), polarEpochUnixMs);
    expect(
      DateTime.fromMillisecondsSinceEpoch(polarEpochUnixMs, isUtc: true),
      DateTime.utc(2000, 1, 1),
    );
  });

  test('TimeSystemExplained example: local stamp minus zone offset', () {
    // The SDK doc gives 724060800000000000 ns for 08:00 local (UTC+02:00);
    // that stamp is 2022-12-11 08:00 counted from the local epoch, so 06:00 UTC.
    final ms = polarNsToUnixMs(724060800000000000, zoneOffsetFor: plusTwo);
    expect(
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      DateTime.utc(2022, 12, 11, 6),
    );
  });

  test('HR timestamps are 1 Hz from start', () {
    expect(hrTimestamps(1000, 3), [1000, 2000, 3000]);
    expect(hrTimestamps(1000, 0), isEmpty);
  });

  test('PPI timestamps accumulate when device stamps are zero', () {
    expect(ppiTimestamps(10000, [800, 820, 790], [0, 0, 0]), [
      10800,
      11620,
      12410,
    ]);
  });

  test('PPI timestamps prefer non-zero device stamps', () {
    final ns = 724060800000000000;
    final startMs = ns ~/ 1000000 + polarEpochUnixMs - 5000;
    final ts = ppiTimestamps(startMs, [800, 800], [ns, 0], zoneOffsetFor: utc);
    expect(ts[0], ns ~/ 1000000 + polarEpochUnixMs);
    expect(ts[1], ts[0] + 800);
  });

  test('PPI timestamps ignore device stamps far from the start', () {
    // Seen on a Verity Sense: stamps count up correctly but start in 2000.
    final base = 18014355630 * 1000000; // ns since 2000 → July 2000
    final ts = ppiTimestamps(
      1794235646000,
      [405, 1165],
      [base + 405 * 1000000, base + 1570 * 1000000],
      zoneOffsetFor: utc,
    );
    expect(ts, [1794235646405, 1794235647570]);
  });

  test('minuteFloor', () {
    expect(minuteFloor(125999), 120000);
    expect(minuteFloor(120000), 120000);
  });
}
