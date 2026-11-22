import 'dart:math' as math;

import 'models.dart';

/// Great-circle distance in metres between two positions in degrees.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8; // mean earth radius, m
  const rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad;
  final dLon = (lon2 - lon1) * rad;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * rad) *
          math.cos(lat2 * rad) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Adds up the length of a walk one fix at a time.
///
/// A fix counts when its accuracy is [maxAccuracyM] or better and it lies at
/// least [minStepM] from the last fix that counted. GPS wanders a few metres
/// around someone who stands still; without the step that wandering adds up
/// to hundreds of metres an hour.
class TrackMeter {
  static const maxAccuracyM = 25.0;
  static const minStepM = 5.0;

  double distanceM = 0;
  WalkPoint? _last;

  void add(WalkPoint p) {
    final acc = p.accM;
    if (acc != null && acc > maxAccuracyM) return;
    final last = _last;
    if (last == null) {
      _last = p;
      return;
    }
    final d = haversineM(last.lat, last.lon, p.lat, p.lon);
    if (d < minStepM) return;
    distanceM += d;
    _last = p;
  }
}

/// The length of a walk in metres (see [TrackMeter]).
double trackDistanceM(Iterable<WalkPoint> points) {
  final m = TrackMeter();
  points.forEach(m.add);
  return m.distanceM;
}
