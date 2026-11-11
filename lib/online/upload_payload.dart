import 'dart:convert';
import 'dart:typed_data';

import '../data/repository.dart';
import '../polar/models.dart';

/// The name mon knows a recording type by, or null for a type that is not
/// uploaded (only heart rate, pulse intervals and movement are stored).
String? monType(PolarDataType t) => switch (t) {
  PolarDataType.hr => 'hr',
  PolarDataType.ppi => 'ppi',
  PolarDataType.acc => 'acc',
  _ => null,
};

/// The `recordings.type` values that are uploaded, for SQL.
final uploadedWireTypes = [
  for (final t in PolarDataType.values)
    if (monType(t) != null) t.wire,
];

/// One recording as `POST /api/heild/upload` on mon takes it (see
/// `web/sites/mon/api/lib/heild.dart`, which is the other end of this):
/// the recording, all of its raw samples, and the per-minute statistics of
/// the minutes it covers.
///
/// Nothing here says whose recording it is. mon takes that from the token.
///
/// Times are Unix milliseconds. Samples go as parallel lists, one per
/// column, which is a third the size of a list of objects. Movement goes as
/// the compressed chunks exactly as they are stored here.
Future<Map<String, Object?>> buildUpload(
  Repository repo,
  RecordingRow r,
) async {
  final db = repo.db;
  final type = monType(r.type);
  if (type == null) {
    throw ArgumentError('${r.type.wire} recordings are not uploaded');
  }
  final body = <String, Object?>{
    'device_id': r.deviceId,
    'type': type,
    'source': r.source,
    'start_ms': r.startMs,
    'end_ms': r.endMs,
    'sample_count': r.sampleCount,
    'rate_hz': r.rateHz,
    'range': r.range,
  };

  switch (r.type) {
    case PolarDataType.hr:
      final rows = await db.rawQuery(
        'SELECT ts_ms, hr, contact FROM hr_samples '
        'WHERE recording_id = ? ORDER BY ts_ms',
        [r.id],
      );
      body['hr'] = {
        'ts_ms': [for (final m in rows) m['ts_ms']],
        'hr': [for (final m in rows) m['hr']],
        'contact': [for (final m in rows) m['contact']],
      };
    case PolarDataType.ppi:
      final rows = await db.rawQuery(
        'SELECT ts_ms, ppi, error_estimate, hr, blocker, skin_contact '
        'FROM ppi_samples WHERE recording_id = ? ORDER BY ts_ms',
        [r.id],
      );
      body['ppi'] = {
        'ts_ms': [for (final m in rows) m['ts_ms']],
        'ppi': [for (final m in rows) m['ppi']],
        'error_estimate': [for (final m in rows) m['error_estimate']],
        'hr': [for (final m in rows) m['hr']],
        'blocker': [for (final m in rows) m['blocker']],
        'skin_contact': [for (final m in rows) m['skin_contact']],
      };
    case PolarDataType.acc:
      final rows = await db.rawQuery(
        'SELECT start_ms, end_ms, sample_count, rate_hz, data '
        'FROM acc_chunks WHERE recording_id = ? ORDER BY start_ms',
        [r.id],
      );
      body['acc'] = [
        for (final m in rows)
          {
            'start_ms': m['start_ms'],
            'end_ms': m['end_ms'],
            'sample_count': m['sample_count'],
            'rate_hz': m['rate_hz'],
            'data': base64Encode(m['data'] as Uint8List),
          },
      ];
    default:
      break;
  }

  // The minutes this recording touches. A minute's figures are computed over
  // everything stored for it, so a minute shared with a neighbouring
  // recording is sent with both and mon keeps the newer copy, which is the
  // same numbers.
  final minutes = await db.rawQuery(
    'SELECT minute_ms, n, mean, min, max, extra FROM minute_stats '
    'WHERE type = ? AND minute_ms >= ? AND minute_ms <= ? ORDER BY minute_ms',
    [r.type.wire, r.startMs - r.startMs % 60000, r.endMs],
  );
  body['minutes'] = [
    for (final m in minutes)
      {
        'minute_ms': m['minute_ms'],
        'n': m['n'],
        'mean': m['mean'],
        'min': m['min'],
        'max': m['max'],
        'extra': m['extra'],
      },
  ];
  return body;
}
