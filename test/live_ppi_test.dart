import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/polar/models.dart';
import 'package:heild/state/live_ppi.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

PpiSample beat(
  int ppi, {
  int error = 10,
  bool blocker = false,
  bool skin = true,
}) => PpiSample(
  ppi: ppi,
  errorEstimate: error,
  hr: 60000 ~/ ppi,
  blockerBit: blocker,
  skinContactStatus: skin,
  skinContactSupported: true,
  timeStamp: 0,
);

void main() {
  sqfliteFfiInit();

  group('PpiSession', () {
    test('start is the first arrival minus the intervals in that batch', () {
      final s = PpiSession('24BE2139');
      s.addBatch(100000, [beat(800), beat(820), beat(790)]);
      expect(s.startMs, 100000 - 2410);
      expect(s.lastBatchMs, 100000);
      expect(s.length, 3);
    });

    test('flags are packed like offline PPI', () {
      final s = PpiSession('24BE2139');
      s.addBatch(1000, [
        beat(800),
        beat(800, blocker: true),
        beat(800, skin: false),
      ]);
      expect(s.flags, [2 | 4, 1 | 2 | 4, 4]);
      expect(PpiSession.isGood(s.flags[0], 10), isTrue);
      expect(PpiSession.isGood(s.flags[1], 10), isFalse);
      expect(PpiSession.isGood(s.flags[0], 31), isFalse);
    });

    test('good beats and RMSSD respect the window and break at bad beats', () {
      final s = PpiSession('24BE2139');
      s.addBatch(10000, [beat(800), beat(820), beat(800)]); // diffs 20, 20
      s.addBatch(15000, [
        beat(900, blocker: true), // breaks the sequence, not counted
        beat(1000),
        beat(1040), // diff 40
        beat(1000, error: 50), // too noisy, breaks again
        beat(1200),
      ]);
      expect(s.goodBeatsSince(0), 6);
      expect(s.goodBeatsSince(15000), 3);
      // Since 0: diffs 20, 20, 40 → sqrt((400+400+1600)/3).
      expect(s.rmssdSince(0), closeTo(28.284271, 1e-5));
      // Since 15000: only one diff (40) → not enough.
      expect(s.rmssdSince(15000), isNull);
    });

    test(
      'toPacked round-trips through the repository and grows in place',
      () async {
        final db = await HeildDb.open(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        final repo = Repository(db);
        final s = PpiSession('24BE2139');
        final t0 = DateTime(2026, 11, 9, 16).millisecondsSinceEpoch;
        s.addBatch(t0 + 2400, [beat(800), beat(800), beat(800)]);
        await repo.storeRecording('24BE2139', s.toPacked()!, source: 'live');
        s.addBatch(t0 + 4000, [beat(800, blocker: true), beat(800)]);
        await repo.storeRecording('24BE2139', s.toPacked()!, source: 'live');

        final recs = await repo.recordings(type: PolarDataType.ppi);
        expect(recs.length, 1);
        final r = recs.single;
        expect(r.source, 'live');
        expect(r.startMs, t0);
        expect(r.sampleCount, 5);
        expect(r.endMs, t0 + 5 * 800);
        final rows = await repo.ppiRows(r.id);
        expect(rows.map((x) => x.tsMs - t0), [800, 1600, 2400, 3200, 4000]);
        expect(rows[3].blocker, isTrue);
        final stats = await repo.stats(PolarDataType.ppi, t0, t0 + 60000);
        expect(stats.single.n, 4); // blocker excluded
        expect(stats.single.extra, 0); // all intervals equal
        await db.close();
      },
    );

    test('toPacked is null while empty', () {
      expect(PpiSession('x').toPacked(), isNull);
    });
  });
}
