/// One GPS fix of a walk, as Android gave it.
class WalkPoint {
  const WalkPoint({
    required this.tsMs,
    required this.lat,
    required this.lon,
    this.accM,
    this.altM,
    this.speedMps,
  });

  /// From the event channel `heild/walk/points` (see `WalkBridge.kt`).
  factory WalkPoint.fromEvent(Map<Object?, Object?> m) => WalkPoint(
    tsMs: (m['tsMs'] as num).toInt(),
    lat: (m['lat'] as num).toDouble(),
    lon: (m['lon'] as num).toDouble(),
    accM: (m['acc'] as num?)?.toDouble(),
    altM: (m['alt'] as num?)?.toDouble(),
    speedMps: (m['speed'] as num?)?.toDouble(),
  );

  /// Row of `walk_points`.
  factory WalkPoint.fromRow(Map<String, Object?> m) => WalkPoint(
    tsMs: m['ts_ms'] as int,
    lat: (m['lat'] as num).toDouble(),
    lon: (m['lon'] as num).toDouble(),
    accM: (m['acc_m'] as num?)?.toDouble(),
    altM: (m['alt_m'] as num?)?.toDouble(),
    speedMps: (m['speed_mps'] as num?)?.toDouble(),
  );

  /// The time of the fix, Unix ms.
  final int tsMs;
  final double lat;
  final double lon;

  /// Horizontal accuracy in metres (68 % radius), when the fix has one.
  final double? accM;

  /// Metres above mean sea level on Android 14 and later, above the WGS84
  /// ellipsoid before that.
  final double? altM;

  /// Metres per second, as the GPS chip measured it.
  final double? speedMps;
}

/// Row of `walks`.
class WalkRow {
  WalkRow.fromMap(Map<String, Object?> m)
    : id = m['id'] as int,
      startMs = m['start_ms'] as int,
      endMs = m['end_ms'] as int,
      ended = m['ended'] == 1,
      pointCount = m['point_count'] as int,
      distanceM = (m['distance_m'] as num).toDouble(),
      sentMs = m['sent_ms'] as int?;

  final int id;

  /// When Start was pressed, and Stop (or the last stored fix of a walk whose
  /// process was killed).
  final int startMs;
  final int endMs;

  /// False while it is being recorded.
  final bool ended;
  final int pointCount;

  /// `trackDistanceM` of its points.
  final double distanceM;
  final int? sentMs;

  Duration get duration => Duration(milliseconds: endMs - startMs);
}
