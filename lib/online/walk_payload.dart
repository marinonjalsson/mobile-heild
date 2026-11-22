import '../data/repository.dart';
import '../walk/models.dart';

/// One walk as the heild site takes it (`POST /api/walk`): when it started and
/// ended, its length, and every fix as parallel lists. Accuracy, altitude and
/// speed hold null where a fix lacked them.
///
/// Like `buildUpload` it never names the person: the server takes that from
/// the token. The other end is `web/sites/heild/api/lib/walk.dart`; the two
/// must change together.
Future<Map<String, Object?>> buildWalkUpload(Repository repo, WalkRow w) async {
  final points = await repo.walkPoints(w.id);
  return {
    'start_ms': w.startMs,
    'end_ms': w.endMs,
    'distance_m': w.distanceM,
    'points': {
      'ts_ms': [for (final p in points) p.tsMs],
      'lat': [for (final p in points) p.lat],
      'lon': [for (final p in points) p.lon],
      'acc_m': [for (final p in points) p.accM],
      'alt_m': [for (final p in points) p.altM],
      'speed_mps': [for (final p in points) p.speedMps],
    },
  };
}
