import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/polar/models.dart';
import 'package:heild/polar/packed_recording.dart';
import 'package:heild/state/live_hr.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HrSample hr(int bpm) => HrSample(
  hr: bpm,
  correctedHr: 0,
  ppgQuality: 0,
  rrsMs: const [],
  rrAvailable: false,
  contactStatus: false,
  contactStatusSupported: false,
);

PackedRecording packedHr(List<int> ts, int bpm) {
  final s = LiveHrSession('24BE2139');
  for (final t in ts) {
    s.add(t, hr(bpm));
  }
  return s.toPacked()!;
}

void main() {
  sqfliteFfiInit();

  test('session drops covered seconds and keeps the rest in order', () {
    final s = LiveHrSession('24BE2139');
    for (var i = 0; i < 10; i++) {
      s.add(1000 * i, hr(60 + i));
    }
    s.flushed = 10;
    // An offline recording 3.0 – 6.0 s holds the seconds 3, 4, 5 and 6.
    expect(s.covered(3000, 6000), 4);
    expect(s.tsMs, [0, 1000, 2000, 7000, 8000, 9000]);
    expect(s.hr, [60, 61, 62, 67, 68, 69]);
    expect(s.rewrite, isTrue);
    expect(s.flushed, 0);
    expect(s.covered(50000, 60000), 0);
    expect(s.toPacked()!.flags, everyElement(0)); // contact unsupported
  });

  test('appending samples keeps the recording and stats exact', () async {
    final db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repo = Repository(db);
    final t0 = DateTime(2026, 11, 10, 9).millisecondsSinceEpoch;
    final ts = List<int>.generate(90, (i) => t0 + i * 1000);
    final id = await repo.storeRecording(
      '24BE2139',
      packedHr(ts.sublist(0, 30), 60),
      source: 'live',
      sampleTsMs: ts.sublist(0, 30),
    );
    await repo.appendHr(
      id,
      ts.sublist(30, 90),
      List.filled(60, 80),
      List.filled(60, 0),
    );
    final r = (await repo.recording(id))!;
    expect(r.sampleCount, 90);
    expect(r.endMs, ts.last);
    final stats = await repo.stats(PolarDataType.hr, t0, t0 + 120000);
    expect(stats.map((b) => b.n), [60, 30]);
    expect(stats[0].mean, closeTo((30 * 60 + 30 * 80) / 60, 1e-9));
    expect(stats[1].mean, 80);
    await db.close();
  });

  test('a session whose start moved replaces its stored copy', () async {
    final db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repo = Repository(db);
    final t0 = DateTime(2026, 11, 9, 15).millisecondsSinceEpoch;
    final s = LiveHrSession('24BE2139');
    for (var i = 0; i < 120; i++) {
      s.add(t0 + i * 1000, hr(65));
    }
    Future<void> flush() async {
      s.storedId = await repo.storeRecording(
        s.deviceId,
        s.toPacked()!,
        source: 'live',
        sampleTsMs: List<int>.of(s.tsMs),
        replaceId: s.storedId,
      );
    }

    await flush();
    // The first minute arrives from the sensor: our copy of it goes.
    s.covered(t0, t0 + 59000); // end_ms of a 60-sample offline recording
    expect(s.length, 60);
    await flush();
    final recs = await repo.recordings(type: PolarDataType.hr);
    expect(recs.length, 1);
    expect(recs.single.startMs, t0 + 60000);
    expect(recs.single.sampleCount, 60);
    expect(recs.single.source, 'live');
    await db.close();
  });
}
