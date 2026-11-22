import 'package:flutter_test/flutter_test.dart';
import 'package:heild/walk/models.dart';
import 'package:heild/walk/track.dart';

void main() {
  // One degree of latitude is 111.195 km on a sphere of the mean radius.
  const mPerDegLat = 111195.0;

  WalkPoint at(int s, double northM, {double? acc = 5}) => WalkPoint(
    tsMs: s * 1000,
    lat: 64.0 + northM / mPerDegLat,
    lon: -21.9,
    accM: acc,
  );

  test('haversine: a degree of latitude, and of longitude at 60° north', () {
    expect(haversineM(64, -21.9, 65, -21.9), closeTo(mPerDegLat, 1));
    expect(haversineM(60, 10, 60, 11), closeTo(mPerDegLat / 2, 100));
    expect(haversineM(64, -21.9, 64, -21.9), 0);
  });

  test('a straight walk adds up to its length', () {
    // 1.4 m/s for 100 s: fixes closer than the 5 m step are passed over, but
    // nothing of the way is lost.
    final points = [for (var s = 0; s <= 100; s++) at(s, s * 1.4)];
    expect(trackDistanceM(points), closeTo(140, 5));
  });

  test('standing still adds nothing', () {
    final points = [for (var s = 0; s < 600; s++) at(s, s.isEven ? 0 : 3.5)];
    expect(trackDistanceM(points), 0);
  });

  test('a poor fix is passed over', () {
    final points = [
      at(0, 0),
      at(1, 400, acc: 80), // a jump while GPS was lost
      at(2, 10),
    ];
    expect(trackDistanceM(points), closeTo(10, 0.1));
  });

  test('a fix without an accuracy counts', () {
    expect(
      trackDistanceM([at(0, 0, acc: null), at(1, 20, acc: null)]),
      closeTo(20, 0.1),
    );
  });
}
