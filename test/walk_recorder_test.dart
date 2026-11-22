import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/state/walk_recorder.dart';
import 'package:heild/walk/models.dart';
import 'package:heild/walk/walk_bridge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The Kotlin side as far as the recorder can tell.
class FakeWalkBridge implements WalkBridge {
  bool running = false;
  PlatformException? refuse;
  final fixes = StreamController<WalkPoint>.broadcast(sync: true);

  @override
  Future<void> start() async {
    if (refuse != null) throw refuse!;
    running = true;
  }

  @override
  Future<void> stop() async => running = false;

  @override
  Future<bool> isRunning() async => running;

  @override
  Stream<WalkPoint> points() => fixes.stream;
}

void main() {
  sqfliteFfiInit();
  late HeildDb db;
  late Repository repo;
  late FakeWalkBridge bridge;
  late WalkRecorder walk;
  var now = DateTime(2026, 11, 22, 14);

  WalkPoint fix(int second, double northM) => WalkPoint(
    tsMs: now.millisecondsSinceEpoch + second * 1000,
    lat: 64.0 + northM / 111195.0,
    lon: -21.9,
    accM: 5,
  );

  setUp(() async {
    db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = Repository(db);
    bridge = FakeWalkBridge();
    now = DateTime(2026, 11, 22, 14);
    walk = WalkRecorder(bridge, repo, now: () => now);
  });

  tearDown(() async {
    walk.dispose();
    await db.close();
  });

  test('start, fixes, stop: a finished walk with its fixes', () async {
    var finished = 0;
    walk.onFinished = () => finished++;
    await walk.start();
    expect(walk.recording, isTrue);
    expect(bridge.running, isTrue);
    expect(walk.last, isNull);

    bridge.fixes.add(fix(1, 0));
    bridge.fixes.add(fix(2, 10));
    bridge.fixes.add(fix(2, 10)); // Android repeats one
    await walk.flush();
    expect((await repo.walkPoints(1)), hasLength(2));
    expect(await repo.walks(), isEmpty, reason: 'still being recorded');

    bridge.fixes.add(fix(3, 30));
    expect(walk.points, hasLength(3));
    expect(walk.distanceM, closeTo(30, 0.1));

    final version = walk.version;
    now = now.add(const Duration(seconds: 5));
    await walk.stop();
    expect(walk.recording, isFalse);
    expect(bridge.running, isFalse);
    expect(finished, 1);
    expect(walk.version, greaterThan(version));

    final w = (await repo.walks()).single;
    expect(w.pointCount, 3);
    expect(w.distanceM, closeTo(30, 0.1));
    expect(w.duration, const Duration(seconds: 5));

    bridge.fixes.add(fix(9, 99)); // a straggler after Stop
    await walk.flush();
    expect(await repo.walkPoints(w.id), hasLength(3));
  });

  test('stopped before the first fix: no walk', () async {
    var finished = 0;
    walk.onFinished = () => finished++;
    await walk.start();
    await walk.stop();
    expect(await repo.db.query('walks'), isEmpty);
    expect(finished, 0);
  });

  test(
    'permission refused: nothing starts, and the page is told why',
    () async {
      walk.ensurePermission = () async => false;
      await walk.start();
      expect(walk.recording, isFalse);
      expect(bridge.running, isFalse);
      expect(walk.error, contains('location permission'));
      expect(await repo.db.query('walks'), isEmpty);
    },
  );

  test('location switched off', () async {
    bridge.refuse = PlatformException(code: 'LocationOff');
    await walk.start();
    expect(walk.recording, isFalse);
    expect(walk.error, 'Location is switched off on the phone.');
    expect(await repo.db.query('walks'), isEmpty);

    bridge.refuse = null;
    await walk.start();
    expect(walk.recording, isTrue);
    expect(walk.error, isNull);
    await walk.stop();
  });

  test('init ends the walk a killed process left open', () async {
    final id = await repo.createWalk(1000);
    await repo.appendWalkPoints(id, [fix(1, 0), fix(2, 10)], 10);
    bridge.running = true; // the service outlived a Dart restart

    await walk.init();
    expect(bridge.running, isFalse);
    final w = (await repo.walks()).single;
    expect(w.ended, isTrue);
    expect(w.endMs, fix(2, 10).tsMs);
  });
}
