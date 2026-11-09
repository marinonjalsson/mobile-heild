import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/acc_codec.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/polar_time.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/polar/models.dart';
import 'package:heild/polar/packed_recording.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds the Polar nanosecond stamp for a phone-local [DateTime].
int polarNs(DateTime local) {
  final ms = local.millisecondsSinceEpoch + local.timeZoneOffset.inMilliseconds;
  return (ms - polarEpochUnixMs) * 1000000;
}

PackedRecording hrRecording(
  DateTime start,
  List<int> hr, {
  int flags = 3, // contact supported + on skin
}) => PackedRecording(
  type: PolarDataType.hr,
  startTimeIso: start.toIso8601String(),
  settings: null,
  sampleCount: hr.length,
  hr: Int32List.fromList(hr),
  flags: Uint8List.fromList(List.filled(hr.length, flags)),
);

PackedRecording ppiRecording(
  DateTime start,
  List<int> ppi, {
  List<int> blockers = const [],
}) => PackedRecording(
  type: PolarDataType.ppi,
  startTimeIso: start.toIso8601String(),
  settings: null,
  sampleCount: ppi.length,
  ts: Int64List(ppi.length),
  ppi: Int32List.fromList(ppi),
  errorEstimate: Int32List(ppi.length),
  hr: Int32List.fromList(List.filled(ppi.length, 60)),
  flags: Uint8List.fromList([
    for (var i = 0; i < ppi.length; i++) blockers.contains(i) ? 1 : 0,
  ]),
);

PackedRecording accRecording(
  DateTime start,
  int seconds,
  int rateHz, {
  int base = 1000,
}) {
  final n = seconds * rateHz;
  final ts = Int64List(n);
  final xyz = Int32List(n * 3);
  final startNs = polarNs(start);
  for (var i = 0; i < n; i++) {
    ts[i] = startNs + i * (1000000000 ~/ rateHz);
    xyz[i * 3] = 0;
    xyz[i * 3 + 1] = 0;
    xyz[i * 3 + 2] = base + (i % 2 == 0 ? 10 : -10);
  }
  return PackedRecording(
    type: PolarDataType.acc,
    startTimeIso: start.toIso8601String(),
    settings: SensorSettingOptions({
      SettingType.sampleRate: [rateHz],
      SettingType.range: [8],
      SettingType.resolution: [16],
    }),
    sampleCount: n,
    ts: ts,
    xyz: xyz,
  );
}

void main() {
  sqfliteFfiInit();
  late HeildDb db;
  late Repository repo;

  setUp(() async {
    db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = Repository(db);
  });

  tearDown(() => db.close());

  test('ACC chunk codec round trip', () {
    final xyz = Int32List.fromList([1, -2, 3, 16000, -16000, 0]);
    expect(decodeAccChunk(encodeAccChunk(xyz, 0, 2)), xyz);
    expect(decodeAccChunk(encodeAccChunk(xyz, 1, 1)), [16000, -16000, 0]);
  });

  test('HR recording: rows, end time and minute stats', () async {
    final start = DateTime(2026, 11, 9, 10, 0, 30);
    final hr = List<int>.generate(90, (i) => 60 + i % 10);
    final id = await repo.storeRecording('24BE2139', hrRecording(start, hr));

    final rec = (await repo.recording(id))!;
    expect(rec.type, PolarDataType.hr);
    expect(rec.startMs, start.millisecondsSinceEpoch);
    expect(rec.endMs, start.millisecondsSinceEpoch + 89 * 1000);
    expect(rec.sampleCount, 90);
    expect(rec.sent, isFalse);

    final rows = await repo.hrRows(id, limit: 3);
    expect(rows.map((r) => r.hr), [60, 61, 62]);
    expect(rows.first.contact, isTrue);

    // A sensor that reports no contact information (Verity Sense) → null.
    final id2 = await repo.storeRecording(
      '24BE2139',
      hrRecording(start.add(const Duration(hours: 1)), [60], flags: 0),
    );
    expect((await repo.hrRows(id2)).single.contact, isNull);
    final id3 = await repo.storeRecording(
      '24BE2139',
      hrRecording(start.add(const Duration(hours: 2)), [60], flags: 2),
    );
    expect((await repo.hrRows(id3)).single.contact, isFalse);

    final stats = await repo.stats(
      PolarDataType.hr,
      start.millisecondsSinceEpoch - 60000,
      start.millisecondsSinceEpoch + 180000,
    );
    // 10:00:30-10:00:59 (30 samples), 10:01 (60 samples).
    expect(stats.map((s) => s.n), [30, 60]);
    expect(stats[1].min, 60);
    expect(stats[1].max, 69);
    expect(stats[1].extra, isNull);
  });

  test('PPI recording accumulates timestamps and computes RMSSD', () async {
    final start = DateTime(2026, 11, 9, 12);
    final ppi = [800, 820, 800, 820];
    final id = await repo.storeRecording('24BE2139', ppiRecording(start, ppi));
    final rows = await repo.ppiRows(id);
    expect(rows.map((r) => r.tsMs - start.millisecondsSinceEpoch), [
      800,
      1620,
      2420,
      3240,
    ]);
    final rec = (await repo.recording(id))!;
    expect(rec.endMs, start.millisecondsSinceEpoch + 3240);
    final stats = await repo.stats(
      PolarDataType.ppi,
      start.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch + 60000,
    );
    expect(stats.single.n, 4);
    expect(stats.single.mean, 810);
    expect(stats.single.extra, closeTo(20, 1e-9));
  });

  test('ACC recording is chunked per minute with |a| stats', () async {
    final start = DateTime(2026, 11, 9, 8, 0, 50);
    final id = await repo.storeRecording(
      '24BE2139',
      accRecording(start, 20, 25),
    );
    final chunks = await repo.accChunks(id);
    expect(chunks.length, 2);
    expect(chunks[0].sampleCount, 10 * 25);
    expect(chunks[1].sampleCount, 10 * 25);
    expect(chunks[0].rateHz, 25);
    final samples = await repo.accChunkSamples(chunks[0].id);
    expect(samples.length, 10 * 25 * 3);
    expect(samples[2], 1010);
    expect(samples[5], 990);

    final rec = (await repo.recording(id))!;
    expect(rec.rateHz, 25);
    expect(rec.range, 8);
    expect(rec.endMs - rec.startMs, closeTo(20000 - 40, 2));

    final stats = await repo.stats(
      PolarDataType.acc,
      start.millisecondsSinceEpoch - 60000,
      start.millisecondsSinceEpoch + 120000,
    );
    expect(stats.length, 2);
    expect(stats[0].mean, closeTo(1000, 1e-6));
    expect(stats[0].extra, closeTo(10, 1e-6));
  });

  test('re-storing the same recording replaces it, stats stay exact', () async {
    final start = DateTime(2026, 11, 9, 10);
    final r = hrRecording(start, List.filled(60, 70));
    await repo.storeRecording('24BE2139', r);
    await repo.storeRecording('24BE2139', r);
    expect(await repo.recordingCount(), 1);
    final stats = await repo.stats(
      PolarDataType.hr,
      start.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch + 60000,
    );
    expect(stats.single.n, 60);
    expect(stats.single.mean, 70);
  });

  test('PPI: blockers break the RMSSD sequence, overlaps pool', () async {
    final start = DateTime(2026, 11, 9, 12);
    // A: diffs 20, 20, 20 → sum of squares 1200 over 3.
    await repo.storeRecording(
      '24BE2139',
      ppiRecording(start, [800, 820, 800, 820]),
    );
    // B, same minute: 1000, [blocked], 1000 → the blocked beat is excluded
    // and no difference spans it.
    await repo.storeRecording(
      '24BE2139',
      ppiRecording(
        start.add(const Duration(seconds: 10)),
        [1000, 1100, 1000],
        blockers: [1],
      ),
    );
    final stats = await repo.stats(
      PolarDataType.ppi,
      start.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch + 60000,
    );
    expect(stats.single.n, 6);
    expect(stats.single.mean, closeTo((3240 + 2000) / 6, 1e-9));
    expect(stats.single.extra, closeTo(20, 1e-9));
  });

  test('PPI: a difference across a minute boundary counts', () async {
    final start = DateTime(2026, 11, 9, 12, 0, 59);
    // Samples at :59.800, 12:01:00.600, 12:01:01.400 → both diffs are 0 but
    // the second minute must have an RMSSD (2 diffs), not null.
    await repo.storeRecording('24BE2139', ppiRecording(start, [800, 800, 800]));
    final stats = await repo.stats(
      PolarDataType.ppi,
      start.millisecondsSinceEpoch - 59000,
      start.millisecondsSinceEpoch + 61000,
    );
    expect(stats.length, 2);
    expect(stats[0].extra, isNull);
    expect(stats[1].n, 2);
    expect(stats[1].extra, 0);
  });

  test('ACC: two recordings in one minute pool the deviation', () async {
    final start = DateTime(2026, 11, 9, 8, 0, 0);
    await repo.storeRecording('24BE2139', accRecording(start, 10, 25));
    await repo.storeRecording(
      '24BE2139',
      accRecording(start.add(const Duration(seconds: 20)), 10, 25, base: 1100),
    );
    final stats = await repo.stats(
      PolarDataType.acc,
      start.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch + 60000,
    );
    expect(stats.single.n, 500);
    expect(stats.single.mean, closeTo(1050, 1e-6));
    // Pooled: sqrt(10² + 50²), not the 10 a weighted mean of stds would give.
    expect(stats.single.extra, closeTo(50.990195, 1e-5));
  });

  test('deleting a recording and rebuilding keep stats exact', () async {
    final start = DateTime(2026, 11, 9, 10);
    final keep = await repo.storeRecording(
      '24BE2139',
      hrRecording(start, List.filled(60, 70)),
    );
    final drop = await repo.storeRecording(
      '24BE2139',
      hrRecording(start.add(const Duration(seconds: 30)), List.filled(60, 90)),
    );
    final range = (
      start.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch + 120000,
    );
    var stats = await repo.stats(PolarDataType.hr, range.$1, range.$2);
    expect(stats.map((s) => s.n), [90, 30]);
    await repo.deleteRecording(drop);
    stats = await repo.stats(PolarDataType.hr, range.$1, range.$2);
    expect(stats.single.n, 60);
    expect(stats.single.max, 70);
    final before = stats.single;
    expect(await repo.rebuildMinuteStats(), 1);
    stats = await repo.stats(PolarDataType.hr, range.$1, range.$2);
    expect(stats.single.n, before.n);
    expect(stats.single.mean, before.mean);
    expect(await repo.recording(keep), isNotNull);
  });

  test('hourly buckets aggregate minutes', () async {
    final start = DateTime(2026, 11, 9, 10);
    await repo.storeRecording(
      '24BE2139',
      hrRecording(
        start,
        List<int>.generate(3600, (i) => 50 + (i ~/ 1800) * 20),
      ),
    );
    final day = DateTime(2026, 11, 9);
    final stats = await repo.stats(
      PolarDataType.hr,
      day.millisecondsSinceEpoch,
      day.add(const Duration(days: 1)).millisecondsSinceEpoch,
      bucketMs: 3600000,
      alignMs: day.millisecondsSinceEpoch,
    );
    expect(stats.single.startMs, start.millisecondsSinceEpoch);
    expect(stats.single.n, 3600);
    expect(stats.single.mean, 60);
    expect(stats.single.min, 50);
    expect(stats.single.max, 70);
  });

  test('retention removes only old recordings marked sent', () async {
    final now = DateTime(2026, 11, 9, 12).millisecondsSinceEpoch;
    final old = DateTime(2026, 9, 1, 10);
    final oldSent = await repo.storeRecording(
      '24BE2139',
      hrRecording(old, List.filled(60, 60)),
    );
    final oldUnsent = await repo.storeRecording(
      '24BE2139',
      hrRecording(old.add(const Duration(hours: 1)), List.filled(60, 60)),
    );
    final recent = await repo.storeRecording(
      '24BE2139',
      hrRecording(DateTime(2026, 11, 8), List.filled(60, 60)),
    );
    await repo.markSent(oldSent, true, nowMs: now);
    await repo.markSent(recent, true, nowMs: now);

    expect(await repo.retention(days: 30, nowMs: now), 1);
    expect(await repo.recording(oldSent), isNull);
    expect(await repo.recording(oldUnsent), isNotNull);
    expect(await repo.recording(recent), isNotNull);
    // Rows cascade.
    expect(await repo.hrRows(oldSent), isEmpty);
    // Minute stats of the deleted hour are gone, the unsent hour's stay.
    final gone = await repo.stats(
      PolarDataType.hr,
      old.millisecondsSinceEpoch,
      old.millisecondsSinceEpoch + 60000,
    );
    expect(gone, isEmpty);
    final kept = await repo.stats(
      PolarDataType.hr,
      old.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      old.add(const Duration(hours: 1)).millisecondsSinceEpoch + 60000,
    );
    expect(kept.single.n, 60);
  });

  test('settings and sync log', () async {
    expect(await repo.getSetting('x'), isNull);
    await repo.setSetting('x', '1');
    expect(await repo.getSetting('x'), '1');
    await repo.setSetting('x', null);
    expect(await repo.getSetting('x'), isNull);
    await repo.log('info', 'hello', nowMs: 5);
    final log = await repo.syncLog();
    expect(log.single.message, 'hello');
    expect(log.single.tsMs, 5);
  });
}
