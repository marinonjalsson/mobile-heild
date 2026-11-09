import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../polar/models.dart';
import '../polar/packed_recording.dart';
import 'acc_codec.dart';
import 'db.dart';
import 'polar_time.dart';

/// Row of `recordings`.
class RecordingRow {
  RecordingRow.fromMap(Map<String, Object?> m)
    : id = m['id'] as int,
      deviceId = m['device_id'] as String,
      type = PolarDataType.fromWire(m['type'] as String),
      startMs = m['start_ms'] as int,
      endMs = m['end_ms'] as int,
      sampleCount = m['sample_count'] as int,
      rateHz = m['rate_hz'] as int?,
      range = m['range'] as int?,
      source = m['source'] as String,
      path = m['path'] as String?,
      fetchedMs = m['fetched_ms'] as int,
      sentMs = m['sent_ms'] as int?;

  final int id;
  final String deviceId;
  final PolarDataType type;
  final int startMs;
  final int endMs;
  final int sampleCount;
  final int? rateHz;
  final int? range;
  final String source;
  final String? path;
  final int fetchedMs;
  final int? sentMs;

  bool get sent => sentMs != null;
  Duration get duration => Duration(milliseconds: endMs - startMs);
}

/// One aggregate bucket (a minute, or coarser when requested).
class StatBucket {
  StatBucket({
    required this.startMs,
    required this.n,
    required this.mean,
    required this.min,
    required this.max,
    this.extra,
  });

  final int startMs;
  final int n;
  final double mean;
  final double min;
  final double max;

  /// PPI: RMSSD in ms. ACC: standard deviation of |a| in mG. HR: null.
  final double? extra;
}

class HrRow {
  HrRow(this.tsMs, this.hr, this.contact);
  final int tsMs;
  final int hr;

  /// Skin contact as reported by the sensor, or null when the recording does
  /// not carry contact information (the Verity Sense never does).
  final bool? contact;
}

/// Values of `hr_samples.contact`.
const hrContactNo = 0;
const hrContactYes = 1;
const hrContactUnknown = 2;

class PpiRow {
  PpiRow({
    required this.tsMs,
    required this.ppi,
    required this.errorEstimate,
    required this.hr,
    required this.blocker,
    required this.skinContact,
  });
  final int tsMs;
  final int ppi;
  final int errorEstimate;
  final int hr;
  final bool blocker;
  final bool skinContact;
}

class AccChunkRow {
  AccChunkRow({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.sampleCount,
    required this.rateHz,
  });
  final int id;
  final int startMs;
  final int endMs;
  final int sampleCount;
  final int rateHz;
}

class SyncLogRow {
  SyncLogRow(this.tsMs, this.level, this.message);
  final int tsMs;
  final String level;
  final String message;
}

/// All reads and writes of [HeildDb]. Ingest runs in one transaction per
/// recording and maintains `minute_stats` so graphs never scan raw samples.
class Repository {
  Repository(this._db);

  final HeildDb _db;
  Database get db => _db.db;

  // ---- settings -------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      await db.delete('settings', where: 'key = ?', whereArgs: [key]);
    } else {
      await db.insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ---- ingest ---------------------------------------------------------------

  /// Stores a fetched recording and returns its id. A recording with the same
  /// device, type and start replaces the earlier copy (re-fetch after a failed
  /// delete on the sensor).
  Future<int> storeRecording(
    String deviceId,
    PackedRecording r, {
    String? path,
    String source = 'offline',
    int Function()? now,
  }) async {
    final nowMs = (now ?? () => DateTime.now().millisecondsSinceEpoch)();
    final startMs = localIsoToUnixMs(r.startTimeIso);
    return db.transaction((txn) async {
      await txn.delete(
        'recordings',
        where: 'device_id = ? AND type = ? AND start_ms = ?',
        whereArgs: [deviceId, r.type.wire, startMs],
      );
      final endMs = switch (r.type) {
        PolarDataType.hr => _hrEnd(startMs, r),
        PolarDataType.ppi => _ppiEnd(startMs, r),
        _ => _tsEnd(startMs, r),
      };
      final id = await txn.insert('recordings', {
        'device_id': deviceId,
        'type': r.type.wire,
        'start_ms': startMs,
        'end_ms': endMs,
        'sample_count': r.sampleCount,
        'rate_hz': r.sampleRateHz,
        'range': r.range,
        'settings_json': r.settings == null
            ? null
            : jsonEncode({
                for (final e in r.settings!.options.entries)
                  e.key.wire: e.value,
              }),
        'source': source,
        'path': path,
        'fetched_ms': nowMs,
      });
      switch (r.type) {
        case PolarDataType.hr:
          await _storeHr(txn, id, startMs, r);
        case PolarDataType.ppi:
          await _storePpi(txn, id, startMs, r);
        case PolarDataType.acc:
          await _storeAcc(txn, id, r);
        default:
          // Other types are kept as a recording row only (no viewer yet).
          break;
      }
      return id;
    });
  }

  int _hrEnd(int startMs, PackedRecording r) =>
      startMs + math.max(0, r.sampleCount - 1) * 1000;

  int _ppiEnd(int startMs, PackedRecording r) {
    final ppi = r.ppi;
    if (ppi == null || ppi.isEmpty) return startMs;
    final ts = ppiTimestamps(startMs, ppi, r.ts ?? Int64List(0));
    return ts.last;
  }

  int _tsEnd(int startMs, PackedRecording r) {
    final ts = r.ts;
    if (ts == null || ts.isEmpty) return startMs;
    return polarNsToUnixMs(ts.last);
  }

  Future<void> _storeHr(
    Transaction txn,
    int id,
    int startMs,
    PackedRecording r,
  ) async {
    final hr = r.hr!;
    final flags = r.flags ?? Uint8List(hr.length);
    final ts = hrTimestamps(startMs, hr.length);
    final batch = txn.batch();
    final minutes = <int>{};
    for (var i = 0; i < hr.length; i++) {
      final f = i < flags.length ? flags[i] : 0;
      final supported = (f & 2) != 0;
      batch.insert('hr_samples', {
        'recording_id': id,
        'ts_ms': ts[i],
        'hr': hr[i],
        'contact': !supported
            ? hrContactUnknown
            : (f & 1) != 0
            ? hrContactYes
            : hrContactNo,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      minutes.add(minuteFloor(ts[i]));
    }
    await batch.commit(noResult: true);
    await _recomputeMinutes(txn, 'HR', minutes);
  }

  Future<void> _storePpi(
    Transaction txn,
    int id,
    int startMs,
    PackedRecording r,
  ) async {
    final ppi = r.ppi!;
    final err = r.errorEstimate ?? Int32List(ppi.length);
    final hr = r.hr ?? Int32List(ppi.length);
    final flags = r.flags ?? Uint8List(ppi.length);
    final ts = ppiTimestamps(startMs, ppi, r.ts ?? Int64List(0));
    final batch = txn.batch();
    final minutes = <int>{};
    var lastTs = -1;
    for (var i = 0; i < ppi.length; i++) {
      // Two samples can share a millisecond when device stamps repeat.
      var t = ts[i];
      if (t <= lastTs) t = lastTs + 1;
      lastTs = t;
      final blocker = (flags[i] & 1) != 0;
      batch.insert('ppi_samples', {
        'recording_id': id,
        'ts_ms': t,
        'ppi': ppi[i],
        'error_estimate': err[i],
        'hr': hr[i],
        'blocker': blocker ? 1 : 0,
        'skin_contact': (flags[i] & 2) != 0 ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      minutes.add(minuteFloor(t));
    }
    await batch.commit(noResult: true);
    await _recomputeMinutes(txn, 'PPI', minutes);
  }

  Future<void> _storeAcc(Transaction txn, int id, PackedRecording r) async {
    final ts = r.ts!;
    final xyz = r.xyz!;
    final rate = r.sampleRateHz ?? 52;
    final n = ts.length;
    if (n == 0) return;
    final unix = List<int>.generate(n, (i) => polarNsToUnixMs(ts[i]));
    final minutes = <int>{};
    final batch = txn.batch();
    var chunkStart = 0;
    var minute = minuteFloor(unix[0]);
    for (var i = 0; i <= n; i++) {
      final boundary = i == n || minuteFloor(unix[i]) != minute;
      if (boundary) {
        final count = i - chunkStart;
        batch.insert('acc_chunks', {
          'recording_id': id,
          'start_ms': unix[chunkStart],
          'end_ms': unix[i - 1],
          'sample_count': count,
          'rate_hz': rate,
          'data': encodeAccChunk(xyz, chunkStart, count),
        });
        minutes.add(minute);
        if (i < n) {
          chunkStart = i;
          minute = minuteFloor(unix[i]);
        }
      }
    }
    await batch.commit(noResult: true);
    await _recomputeMinutes(txn, 'ACC', minutes);
  }

  // ---- minute stats ---------------------------------------------------------

  /// Makes `minute_stats` for [minutes] of [type] a pure function of the raw
  /// rows, so overlapping recordings, re-stores and deletes stay exact.
  ///
  /// HR: samples with hr > 0 (0 = no contact). PPI: non-blocker samples;
  /// `extra` is RMSSD over successive intervals of one recording, the sequence
  /// breaking at blocker samples, with each difference counted in the minute
  /// of its later sample. ACC: |a| over all samples; `extra` is its standard
  /// deviation.
  Future<void> _recomputeMinutes(
    DatabaseExecutor txn,
    String type,
    Iterable<int> minutes,
  ) async {
    for (final m in minutes) {
      final row = switch (type) {
        'HR' => await _hrMinute(txn, m),
        'PPI' => await _ppiMinute(txn, m),
        'ACC' => await _accMinute(txn, m),
        _ => null,
      };
      await txn.delete(
        'minute_stats',
        where: 'type = ? AND minute_ms = ?',
        whereArgs: [type, m],
      );
      if (row != null) {
        await txn.insert('minute_stats', {
          'type': type,
          'minute_ms': m,
          ...row,
        });
      }
    }
  }

  Future<Map<String, Object?>?> _hrMinute(DatabaseExecutor txn, int m) async {
    final r = (await txn.rawQuery(
      'SELECT COUNT(*) n, AVG(hr) mean, MIN(hr) min, MAX(hr) max '
      'FROM hr_samples WHERE hr > 0 AND ts_ms >= ? AND ts_ms < ?',
      [m, m + 60000],
    )).first;
    final n = r['n'] as int;
    if (n == 0) return null;
    return {
      'n': n,
      'mean': (r['mean'] as num).toDouble(),
      'min': (r['min'] as num).toDouble(),
      'max': (r['max'] as num).toDouble(),
      'extra': null,
    };
  }

  Future<Map<String, Object?>?> _ppiMinute(DatabaseExecutor txn, int m) async {
    // Include the preceding minute so the first interval of this minute has
    // its predecessor (a PP interval is well under a minute long).
    final rows = await txn.query(
      'ppi_samples',
      columns: ['recording_id', 'ts_ms', 'ppi', 'blocker'],
      where: 'ts_ms >= ? AND ts_ms < ?',
      whereArgs: [m - 60000, m + 60000],
      orderBy: 'recording_id, ts_ms',
    );
    var n = 0;
    var sum = 0.0;
    var min = double.infinity;
    var max = double.negativeInfinity;
    var diffSq = 0.0;
    var diffs = 0;
    int? prevRec;
    double? prev;
    for (final r in rows) {
      final rec = r['recording_id'] as int;
      if (rec != prevRec) {
        prevRec = rec;
        prev = null;
      }
      final ppi = (r['ppi'] as int).toDouble();
      if ((r['blocker'] as int) != 0 || ppi <= 0) {
        prev = null;
        continue;
      }
      if ((r['ts_ms'] as int) >= m) {
        n++;
        sum += ppi;
        if (ppi < min) min = ppi;
        if (ppi > max) max = ppi;
        if (prev != null) {
          final d = ppi - prev;
          diffSq += d * d;
          diffs++;
        }
      }
      prev = ppi;
    }
    if (n == 0) return null;
    return {
      'n': n,
      'mean': sum / n,
      'min': min,
      'max': max,
      'extra': diffs > 0 ? math.sqrt(diffSq / diffs) : null,
    };
  }

  Future<Map<String, Object?>?> _accMinute(DatabaseExecutor txn, int m) async {
    final chunks = await txn.query(
      'acc_chunks',
      columns: ['data'],
      where: 'start_ms >= ? AND start_ms < ?',
      whereArgs: [m, m + 60000],
    );
    var n = 0;
    var sum = 0.0;
    var sumSq = 0.0;
    var min = double.infinity;
    var max = double.negativeInfinity;
    for (final c in chunks) {
      final xyz = decodeAccChunk(c['data'] as Uint8List);
      for (var i = 0; i + 2 < xyz.length; i += 3) {
        final x = xyz[i].toDouble();
        final y = xyz[i + 1].toDouble();
        final z = xyz[i + 2].toDouble();
        final a = math.sqrt(x * x + y * y + z * z);
        n++;
        sum += a;
        sumSq += a * a;
        if (a < min) min = a;
        if (a > max) max = a;
      }
    }
    if (n == 0) return null;
    final mean = sum / n;
    final v = sumSq / n - mean * mean;
    return {
      'n': n,
      'mean': mean,
      'min': min,
      'max': max,
      'extra': math.sqrt(v < 0 ? 0 : v),
    };
  }

  /// Drops and recomputes every minute stat from the raw rows. Run after the
  /// statistics definitions change. Returns the number of minutes written.
  Future<int> rebuildMinuteStats() => db.transaction((txn) async {
    await txn.delete('minute_stats');
    var count = 0;
    for (final (type, sql) in const [
      (
        'HR',
        'SELECT DISTINCT (ts_ms / 60000) * 60000 m FROM hr_samples WHERE hr > 0',
      ),
      ('PPI', 'SELECT DISTINCT (ts_ms / 60000) * 60000 m FROM ppi_samples'),
      ('ACC', 'SELECT DISTINCT (start_ms / 60000) * 60000 m FROM acc_chunks'),
    ]) {
      final minutes = [for (final r in await txn.rawQuery(sql)) r['m'] as int];
      await _recomputeMinutes(txn, type, minutes);
      count += minutes.length;
    }
    return count;
  });

  // ---- queries --------------------------------------------------------------

  /// Aggregates of [type] between [fromMs] and [toMs], grouped into buckets of
  /// [bucketMs] (60 000 for raw minutes). Buckets are aligned to [alignMs] so
  /// a day view in local time starts at local midnight.
  ///
  /// Over coarser buckets `mean` is the sample-weighted mean and `extra`
  /// (RMSSD, std |a|) the sample-weighted mean of the per-minute values, i.e.
  /// "average short-term HRV / movement", not a pooled recomputation.
  Future<List<StatBucket>> stats(
    PolarDataType type,
    int fromMs,
    int toMs, {
    int bucketMs = 60000,
    int alignMs = 0,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT ((minute_ms - ?) / ?) * ? + ? AS bucket,
             SUM(n) AS n,
             SUM(mean * n) / SUM(n) AS mean,
             MIN(min) AS min,
             MAX(max) AS max,
             SUM(COALESCE(extra, 0) * n) / NULLIF(SUM(CASE WHEN extra IS NULL THEN 0 ELSE n END), 0) AS extra
      FROM minute_stats
      WHERE type = ? AND minute_ms >= ? AND minute_ms < ?
      GROUP BY bucket ORDER BY bucket''',
      [alignMs, bucketMs, bucketMs, alignMs, type.wire, fromMs, toMs],
    );
    return [
      for (final m in rows)
        StatBucket(
          startMs: m['bucket'] as int,
          n: m['n'] as int,
          mean: (m['mean'] as num).toDouble(),
          min: (m['min'] as num).toDouble(),
          max: (m['max'] as num).toDouble(),
          extra: (m['extra'] as num?)?.toDouble(),
        ),
    ];
  }

  Future<List<RecordingRow>> recordings({
    PolarDataType? type,
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await db.query(
      'recordings',
      where: type == null ? null : 'type = ?',
      whereArgs: type == null ? null : [type.wire],
      orderBy: 'start_ms DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(RecordingRow.fromMap).toList();
  }

  Future<RecordingRow?> recording(int id) async {
    final rows = await db.query('recordings', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : RecordingRow.fromMap(rows.first);
  }

  Future<int> recordingCount() async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM recordings'),
      ) ??
      0;

  Future<List<HrRow>> hrRows(
    int recordingId, {
    int limit = 500,
    int offset = 0,
  }) async {
    final rows = await db.query(
      'hr_samples',
      where: 'recording_id = ?',
      whereArgs: [recordingId],
      orderBy: 'ts_ms',
      limit: limit,
      offset: offset,
    );
    return [
      for (final m in rows)
        HrRow(m['ts_ms'] as int, m['hr'] as int, switch (m['contact'] as int) {
          hrContactYes => true,
          hrContactNo => false,
          _ => null,
        }),
    ];
  }

  Future<List<PpiRow>> ppiRows(
    int recordingId, {
    int limit = 500,
    int offset = 0,
  }) async {
    final rows = await db.query(
      'ppi_samples',
      where: 'recording_id = ?',
      whereArgs: [recordingId],
      orderBy: 'ts_ms',
      limit: limit,
      offset: offset,
    );
    return [
      for (final m in rows)
        PpiRow(
          tsMs: m['ts_ms'] as int,
          ppi: m['ppi'] as int,
          errorEstimate: m['error_estimate'] as int,
          hr: m['hr'] as int,
          blocker: (m['blocker'] as int) != 0,
          skinContact: (m['skin_contact'] as int) != 0,
        ),
    ];
  }

  Future<List<AccChunkRow>> accChunks(
    int recordingId, {
    int limit = 500,
    int offset = 0,
  }) async {
    final rows = await db.query(
      'acc_chunks',
      columns: ['id', 'start_ms', 'end_ms', 'sample_count', 'rate_hz'],
      where: 'recording_id = ?',
      whereArgs: [recordingId],
      orderBy: 'start_ms',
      limit: limit,
      offset: offset,
    );
    return [
      for (final m in rows)
        AccChunkRow(
          id: m['id'] as int,
          startMs: m['start_ms'] as int,
          endMs: m['end_ms'] as int,
          sampleCount: m['sample_count'] as int,
          rateHz: m['rate_hz'] as int,
        ),
    ];
  }

  /// Raw samples of one chunk as interleaved x, y, z in mG.
  Future<Int32List> accChunkSamples(int chunkId) async {
    final rows = await db.query(
      'acc_chunks',
      columns: ['data'],
      where: 'id = ?',
      whereArgs: [chunkId],
    );
    if (rows.isEmpty) return Int32List(0);
    return decodeAccChunk(rows.first['data'] as Uint8List);
  }

  /// Latest minute with data per type, for "last seen" displays.
  Future<int?> latestMinute(PolarDataType type) async => Sqflite.firstIntValue(
    await db.rawQuery(
      'SELECT MAX(minute_ms) FROM minute_stats WHERE type = ?',
      [type.wire],
    ),
  );

  // ---- maintenance ----------------------------------------------------------

  Future<void> markSent(int recordingId, bool sent, {int? nowMs}) => db.update(
    'recordings',
    {'sent_ms': sent ? (nowMs ?? DateTime.now().millisecondsSinceEpoch) : null},
    where: 'id = ?',
    whereArgs: [recordingId],
  );

  /// Removes a recording and its rows, and recomputes the minutes it covered.
  Future<void> deleteRecording(int recordingId) async {
    final r = await recording(recordingId);
    if (r == null) return;
    await db.transaction((txn) async {
      await txn.delete('recordings', where: 'id = ?', whereArgs: [r.id]);
      final minutes = <int>[
        for (var m = minuteFloor(r.startMs); m <= r.endMs; m += 60000) m,
      ];
      await _recomputeMinutes(txn, r.type.wire, minutes);
    });
  }

  /// Deletes recordings that ended more than [days] ago **and** were marked
  /// sent, then drops minute stats no recording covers any more. Returns the
  /// number of recordings removed.
  Future<int> retention({int days = 30, int? nowMs}) async {
    final cutoff =
        (nowMs ?? DateTime.now().millisecondsSinceEpoch) - days * 86400000;
    return db.transaction((txn) async {
      final removed = await txn.delete(
        'recordings',
        where: 'end_ms < ? AND sent_ms IS NOT NULL',
        whereArgs: [cutoff],
      );
      await txn.rawDelete(
        '''
        DELETE FROM minute_stats WHERE minute_ms < ? AND NOT EXISTS (
          SELECT 1 FROM recordings r
          WHERE r.type = minute_stats.type
            AND r.start_ms < minute_stats.minute_ms + 60000
            AND r.end_ms >= minute_stats.minute_ms)''',
        [cutoff],
      );
      return removed;
    });
  }

  Future<int> databaseSizeBytes() async {
    if (_db.path == inMemoryDatabasePath) return 0;
    var total = 0;
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = File('${_db.path}$suffix');
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  Future<void> vacuum() => db.execute('VACUUM');

  // ---- sync log -------------------------------------------------------------

  Future<void> log(String level, String message, {int? nowMs}) async {
    await db.insert('sync_log', {
      'ts_ms': nowMs ?? DateTime.now().millisecondsSinceEpoch,
      'level': level,
      'message': message,
    });
    await db.rawDelete(
      'DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 2000)',
    );
  }

  Future<List<SyncLogRow>> syncLog({int limit = 200}) async {
    final rows = await db.query('sync_log', orderBy: 'id DESC', limit: limit);
    return [
      for (final m in rows)
        SyncLogRow(
          m['ts_ms'] as int,
          m['level'] as String,
          m['message'] as String,
        ),
    ];
  }
}

/// Accumulates per-minute statistics during ingest and merges them into
/// `minute_stats` (weighted by sample count when a minute already exists).
