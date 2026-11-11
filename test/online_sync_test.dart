import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heild/auth/oidc.dart';
import 'package:heild/auth/token_store.dart';
import 'package:heild/data/acc_codec.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/polar_time.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/online/mon_client.dart';
import 'package:heild/online/upload_payload.dart';
import 'package:heild/polar/models.dart';
import 'package:heild/polar/packed_recording.dart';
import 'package:heild/state/auth_controller.dart';
import 'package:heild/state/online_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int polarNs(DateTime local) {
  final ms = local.millisecondsSinceEpoch + local.timeZoneOffset.inMilliseconds;
  return (ms - polarEpochUnixMs) * 1000000;
}

PackedRecording hrRecording(DateTime start, List<int> hr) => PackedRecording(
  type: PolarDataType.hr,
  startTimeIso: start.toIso8601String(),
  settings: null,
  sampleCount: hr.length,
  hr: Int32List.fromList(hr),
  flags: Uint8List.fromList(List.filled(hr.length, 0)),
);

PackedRecording ppiRecording(DateTime start, List<int> ppi) => PackedRecording(
  type: PolarDataType.ppi,
  startTimeIso: start.toIso8601String(),
  settings: null,
  sampleCount: ppi.length,
  ts: Int64List(ppi.length),
  ppi: Int32List.fromList(ppi),
  errorEstimate: Int32List(ppi.length),
  hr: Int32List.fromList(List.filled(ppi.length, 60)),
  flags: Uint8List(ppi.length),
);

PackedRecording accRecording(DateTime start, int seconds, int rateHz) {
  final n = seconds * rateHz;
  final ts = Int64List(n);
  final xyz = Int32List(n * 3);
  final startNs = polarNs(start);
  for (var i = 0; i < n; i++) {
    ts[i] = startNs + i * (1000000000 ~/ rateHz);
    xyz[i * 3 + 2] = 1000 + (i.isEven ? 10 : -10);
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

/// mon's upload endpoint, as far as the app can tell: it knows one good
/// token and answers the way the real one was seen to.
class FakeMon {
  String goodToken = 'at-1';
  bool down = false;

  /// Bodies of the requests it accepted, in order.
  final stored = <Map<String, dynamic>>[];
  final tokensSeen = <String>[];

  /// Recording start (ms) → the refusal to give instead of storing it.
  final refuse = <int, (int, String, String)>{};
  (int, String, String)? refuseAll;

  late final client = MockClient((req) async {
    if (down) throw http.ClientException('connection refused');
    expect(req.url.toString(), 'https://mon.loria.is/api/heild/upload');
    final token = req.headers['Authorization']!.substring('Bearer '.length);
    tokensSeen.add(token);
    http.Response no(int status, String error, String message) =>
        http.Response(jsonEncode({'error': error, 'message': message}), status);
    if (token != goodToken) {
      return no(401, 'invalid_token', 'the token is not valid; sign in again');
    }
    final r = refuseAll;
    if (r != null) return no(r.$1, r.$2, r.$3);
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final one = refuse[body['start_ms']];
    if (one != null) return no(one.$1, one.$2, one.$3);
    stored.add(body);
    return http.Response(jsonEncode({'ok': true}), 200);
  });
}

void main() {
  sqfliteFfiInit();

  late HeildDb db;
  late Repository repo;
  late FakeMon mon;
  late AuthController auth;
  late OnlineSyncService online;
  var refreshes = 0;

  final day = DateTime(2026, 11, 11, 9);

  Future<void> signIn() async {
    await auth.load();
    expect(await auth.signIn(), isTrue);
  }

  setUp(() async {
    db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = Repository(db);
    mon = FakeMon();
    refreshes = 0;
    // The sign-in service: userinfo for the sign-in, and a refresh that
    // hands out the token mon currently accepts.
    final authelia = MockClient((req) async {
      if (req.url.path.endsWith('/userinfo')) {
        return http.Response(jsonEncode({'preferred_username': 'marino'}), 200);
      }
      if (req.url.path.endsWith('/token')) {
        refreshes++;
        return http.Response(
          jsonEncode({
            'access_token': mon.goodToken,
            'refresh_token': 'rt-next',
            'expires_in': 3600,
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    auth = AuthController(
      repo,
      client: OidcClient(const OidcConfig(), client: authelia),
      store: MemoryTokenStore(),
      authorizer: () async => TokenSet(
        accessToken: 'at-1',
        refreshToken: 'rt-1',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    online = OnlineSyncService(repo, auth, MonClient(client: mon.client));
  });

  tearDown(() => db.close());

  test('nothing is sent while nobody is signed in', () async {
    await auth.load();
    await repo.storeRecording('24BE2139', hrRecording(day, [60, 61, 62]));
    await online.run();
    expect(mon.tokensSeen, isEmpty);
    expect(await repo.unsentCount(), 1);
    expect(online.lastMessage, isNull);
  });

  test('sends what is waiting, oldest first, and marks it sent', () async {
    final late_ = await repo.storeRecording(
      '24BE2139',
      hrRecording(day.add(const Duration(hours: 2)), [70, 71]),
    );
    final early = await repo.storeRecording(
      '24BE2139',
      hrRecording(day, [60, 61, 62]),
    );
    await signIn();
    await online.run();

    expect(mon.stored.map((b) => b['start_ms']), [
      day.millisecondsSinceEpoch,
      day.add(const Duration(hours: 2)).millisecondsSinceEpoch,
    ]);
    expect(mon.tokensSeen.toSet(), {'at-1'});
    expect((await repo.recording(early))!.sent, isTrue);
    expect((await repo.recording(late_))!.sent, isTrue);
    expect(await repo.unsentCount(), 0);
    expect(online.lastOk, isTrue);
    expect(online.lastMessage, startsWith('sent 2 recordings'));

    final push = (await repo.onlineHistory()).firstWhere(
      (r) => r.kind == 'push',
    );
    expect(push.ok, isTrue);
    expect(push.message, startsWith('sent 2 recordings'));

    // A second run has nothing to do and writes no history.
    final before = (await repo.onlineHistory()).length;
    await online.run();
    expect(mon.stored.length, 2);
    expect((await repo.onlineHistory()).length, before);
    expect(online.lastMessage, 'nothing to send');
  });

  test('a heart-rate recording carries its samples and its minutes, and no '
      'name', () async {
    await repo.storeRecording(
      '24BE2139',
      hrRecording(day, List.generate(90, (i) => 60 + i % 5)),
    );
    await signIn();
    await online.run();

    final b = mon.stored.single;
    expect(b['type'], 'hr');
    expect(b['device_id'], '24BE2139');
    expect(b['source'], 'offline');
    expect(b['sample_count'], 90);
    expect(b.containsKey('person'), isFalse);
    final hr = b['hr'] as Map<String, dynamic>;
    expect((hr['ts_ms'] as List).length, 90);
    expect((hr['ts_ms'] as List).first, day.millisecondsSinceEpoch);
    expect((hr['hr'] as List).take(3), [60, 61, 62]);
    expect((hr['contact'] as List).toSet(), {hrContactUnknown});
    final minutes = b['minutes'] as List;
    expect(minutes.map((m) => m['n']), [60, 30]);
    expect(minutes.first['minute_ms'], day.millisecondsSinceEpoch);
  });

  test('pulse intervals and movement go in their own shapes', () async {
    await repo.storeRecording('24BE2139', ppiRecording(day, [800, 820, 800]));
    await repo.storeRecording(
      '24BE2139',
      accRecording(day.add(const Duration(hours: 1)), 20, 25),
    );
    await signIn();
    await online.run();

    final ppi = mon.stored.firstWhere((b) => b['type'] == 'ppi');
    final p = ppi['ppi'] as Map<String, dynamic>;
    expect(p['ppi'], [800, 820, 800]);
    expect((p['blocker'] as List).length, 3);
    expect((ppi['minutes'] as List).single['extra'], isNotNull); // RMSSD

    final acc = mon.stored.firstWhere((b) => b['type'] == 'acc');
    expect(acc['rate_hz'], 25);
    expect(acc['range'], 8);
    final chunks = acc['acc'] as List;
    expect(chunks.fold<int>(0, (s, c) => s + (c['sample_count'] as int)), 500);
    // The chunk is the phone's own compressed form, byte for byte.
    final xyz = decodeAccChunk(base64Decode(chunks.first['data'] as String));
    expect(xyz.length, (chunks.first['sample_count'] as int) * 3);
    expect(xyz[2], 1010);
  });

  test('a live session is not uploaded', () async {
    await repo.storeRecording(
      '24BE2139',
      hrRecording(day, [60, 61]),
      source: 'live',
      sampleTsMs: [
        day.millisecondsSinceEpoch,
        day.millisecondsSinceEpoch + 1000,
      ],
    );
    await signIn();
    await online.run();
    expect(mon.stored, isEmpty);
    expect(await repo.unsentCount(), 0);
  });

  test('an access token mon no longer takes is refreshed once', () async {
    await repo.storeRecording('24BE2139', hrRecording(day, [60, 61]));
    await signIn();
    mon.goodToken = 'at-2'; // the one the app holds has been replaced
    await online.run();

    expect(mon.tokensSeen, ['at-1', 'at-2']);
    expect(refreshes, 1);
    expect(mon.stored.length, 1);
    expect(await repo.unsentCount(), 0);
  });

  test(
    'a recording mon will never take is skipped, the rest still go',
    () async {
      final bad = await repo.storeRecording('24BE2139', hrRecording(day, [60]));
      final good = await repo.storeRecording(
        '24BE2139',
        hrRecording(day.add(const Duration(hours: 1)), [61]),
      );
      mon.refuse[day.millisecondsSinceEpoch] = (
        400,
        'invalid_recording',
        'the recording starts before 2020',
      );
      await signIn();
      await online.run();

      expect((await repo.recording(bad))!.sent, isFalse);
      expect((await repo.recording(good))!.sent, isTrue);
      expect(online.lastOk, isFalse);
      expect(online.lastMessage, 'sent 1 recordings (1 kB), 1 refused');
      final history = await repo.onlineHistory();
      expect(
        history.any((r) => !r.ok && r.message.contains('before 2020')),
        isTrue,
      );

      // Not offered again in this run of the app.
      final seen = mon.tokensSeen.length;
      await online.run();
      expect(mon.tokensSeen.length, seen);
    },
  );

  test('not in the group: stops, keeps everything, says what to do', () async {
    await repo.storeRecording('24BE2139', hrRecording(day, [60]));
    await repo.storeRecording(
      '24BE2139',
      hrRecording(day.add(const Duration(hours: 1)), [61]),
    );
    mon.refuseAll = (
      403,
      'not_in_group',
      'marino is not in the heild_user group',
    );
    await signIn();
    await online.run();

    expect(mon.tokensSeen.length, 1); // did not go on to the second
    expect(await repo.unsentCount(), 2);
    expect(online.lastOk, isFalse);
    expect(online.lastMessage, contains('not in the heild_user group'));
    expect(online.lastMessage, contains('sign out and sign in again'));
    expect((await repo.onlineHistory()).first.ok, isFalse);
  });

  test(
    'mon unreachable: nothing is marked, and the next run sends it',
    () async {
      await repo.storeRecording('24BE2139', hrRecording(day, [60, 61]));
      await signIn();
      mon.down = true;
      await online.run();
      expect(await repo.unsentCount(), 1);
      expect(online.lastOk, isFalse);
      expect(online.lastMessage, contains('could not be reached'));

      mon.down = false;
      await online.run();
      expect(await repo.unsentCount(), 0);
      expect(online.lastOk, isTrue);
    },
  );

  test('the payload names the types mon knows', () {
    expect(monType(PolarDataType.hr), 'hr');
    expect(monType(PolarDataType.ppi), 'ppi');
    expect(monType(PolarDataType.acc), 'acc');
    expect(uploadedWireTypes, containsAll(['HR', 'PPI', 'ACC']));
    expect(uploadedWireTypes.length, 3);
  });
}
