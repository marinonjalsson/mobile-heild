import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:heild/auth/oidc.dart';
import 'package:heild/auth/token_store.dart';
import 'package:heild/data/db.dart';
import 'package:heild/data/repository.dart';
import 'package:heild/state/auth_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stand-in for Authelia's token, userinfo and revocation endpoints that
/// behaves the way the real one was observed to (4.39.14): refresh tokens are
/// replaced on use and the old one is refused with `invalid_grant`.
class FakeAuthelia {
  String validRefresh = 'rt-1';
  String validAccess = 'at-1';
  int refreshes = 0;
  int revocations = 0;
  bool offline = false;
  Duration delay = Duration.zero;
  Map<String, Object?> profile = {
    'preferred_username': 'marino',
    'name': 'Marinó',
    'email': 'marino@loria.is',
  };

  late final client = MockClient((req) async {
    if (offline) throw http.ClientException('no network');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    switch (req.url.path) {
      case '/api/oidc/token':
        final f = req.bodyFields;
        expect(f['grant_type'], 'refresh_token');
        expect(f['client_id'], 'heild');
        if (f['refresh_token'] != validRefresh) {
          return http.Response(
            jsonEncode({'error': 'invalid_grant', 'error_description': 'no'}),
            400,
          );
        }
        refreshes++;
        validRefresh = 'rt-${refreshes + 1}';
        validAccess = 'at-${refreshes + 1}';
        return http.Response(
          jsonEncode({
            'access_token': validAccess,
            'refresh_token': validRefresh,
            'expires_in': 3600,
            'token_type': 'bearer',
          }),
          200,
        );
      case '/api/oidc/userinfo':
        if (req.headers['Authorization'] != 'Bearer $validAccess') {
          return http.Response(jsonEncode({'error': 'invalid_token'}), 401);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(profile)),
          200,
          headers: {'content-type': 'application/json'},
        );
      case '/api/oidc/revocation':
        revocations++;
        if (req.bodyFields['token'] == validRefresh) validRefresh = 'revoked';
        return http.Response('', 200);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  sqfliteFfiInit();

  late HeildDb db;
  late Repository repo;
  late FakeAuthelia server;
  late MemoryTokenStore store;
  late DateTime now;
  TokenSet? browserResult;
  Object? browserError;

  AuthController controller() => AuthController(
    repo,
    client: OidcClient(
      const OidcConfig(),
      client: server.client,
      now: () => now,
    ),
    store: store,
    authorizer: () async {
      if (browserError != null) throw browserError!;
      return browserResult;
    },
    now: () => now,
  );

  TokenSet fromBrowser() => TokenSet(
    accessToken: server.validAccess,
    refreshToken: server.validRefresh,
    expiresAt: now.add(const Duration(hours: 1)),
  );

  setUp(() async {
    db = await HeildDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = Repository(db);
    server = FakeAuthelia();
    store = MemoryTokenStore();
    now = DateTime(2026, 11, 11, 12);
    browserResult = null;
    browserError = null;
  });

  tearDown(() => db.close());

  test('starts signed out and gives no token', () async {
    final auth = controller();
    await auth.load();
    expect(auth.status, AuthStatus.signedOut);
    expect(await auth.accessToken(), isNull);
  });

  test('sign-in stores the refresh token and the username', () async {
    final auth = controller();
    await auth.load();
    browserResult = fromBrowser();
    expect(await auth.signIn(), isTrue);
    expect(auth.status, AuthStatus.signedIn);
    expect(auth.username, 'marino');
    expect(auth.displayName, 'Marinó');
    expect(auth.email, 'marino@loria.is');
    expect(store.value, 'rt-1');
    // The access token from the browser is used as is: no refresh yet.
    expect(await auth.accessToken(), 'at-1');
    expect(server.refreshes, 0);
    final history = await repo.onlineHistory();
    expect(history.single.message, 'signed in as marino');
    expect(history.single.ok, isTrue);
  });

  test('closing the browser changes nothing and is not an error', () async {
    final auth = controller();
    await auth.load();
    expect(await auth.signIn(), isFalse);
    expect(auth.status, AuthStatus.signedOut);
    expect(auth.lastError, isNull);
    expect(await repo.onlineHistory(), isEmpty);
  });

  test('a failed sign-in is reported and logged', () async {
    final auth = controller();
    await auth.load();
    browserError = OidcException('access_denied', 'no consent');
    expect(await auth.signIn(), isFalse);
    expect(auth.status, AuthStatus.signedOut);
    expect(auth.lastError, 'access_denied: no consent');
    expect((await repo.onlineHistory()).single.ok, isFalse);
    expect(store.value, isNull);
  });

  test('the session survives a restart', () async {
    browserResult = fromBrowser();
    final first = controller();
    await first.load();
    await first.signIn();

    final second = controller();
    await second.load();
    expect(second.status, AuthStatus.signedIn);
    expect(second.username, 'marino');
    expect(second.signedInAt, now);
    // Nothing cached in memory after a restart: one refresh.
    expect(await second.accessToken(), 'at-2');
    expect(store.value, 'rt-2');
  });

  test('an expiring access token is refreshed, and the new refresh token '
      'replaces the old one', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    now = now.add(const Duration(minutes: 59, seconds: 30));
    expect(await auth.accessToken(), 'at-2');
    expect(store.value, 'rt-2');
    expect(await auth.accessToken(), 'at-2');
    expect(server.refreshes, 1);
  });

  test('concurrent callers share one refresh', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    now = now.add(const Duration(hours: 2));
    server.delay = const Duration(milliseconds: 20);
    final tokens = await Future.wait([
      auth.accessToken(),
      auth.accessToken(),
      auth.accessToken(),
    ]);
    expect(tokens, ['at-2', 'at-2', 'at-2']);
    expect(server.refreshes, 1);
    expect(auth.status, AuthStatus.signedIn);
  });

  test('no network keeps the session and tries again later', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    now = now.add(const Duration(hours: 2));
    server.offline = true;
    expect(await auth.accessToken(), isNull);
    expect(auth.status, AuthStatus.signedIn);
    expect(auth.lastError, isNotNull);
    expect(store.value, 'rt-1');
    server.offline = false;
    expect(await auth.accessToken(), 'at-2');
    expect(auth.lastError, isNull);
  });

  test('a refused refresh token ends the session but keeps the name', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    now = now.add(const Duration(hours: 2));
    server.validRefresh = 'somebody-revoked-it';
    expect(await auth.accessToken(), isNull);
    expect(auth.status, AuthStatus.expired);
    expect(auth.username, 'marino');
    expect(store.value, isNull);
    expect((await repo.onlineHistory()).first.ok, isFalse);

    // Still expired after a restart, and signing in again recovers.
    final again = controller();
    await again.load();
    expect(again.status, AuthStatus.expired);
    server.validRefresh = 'rt-9';
    browserResult = fromBrowser();
    expect(await again.signIn(), isTrue);
    expect(again.status, AuthStatus.signedIn);
  });

  test('sign-out revokes on the server and forgets everything here', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    await auth.signOut();
    expect(auth.status, AuthStatus.signedOut);
    expect(auth.username, isNull);
    expect(store.value, isNull);
    expect(server.revocations, 1);
    expect(server.validRefresh, 'revoked');
    expect(await auth.accessToken(), isNull);
    expect(await repo.getSetting('auth_username'), isNull);
    expect((await repo.onlineHistory()).first.message, 'signed out marino');
  });

  test('sign-out works without network', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    server.offline = true;
    await auth.signOut();
    expect(auth.status, AuthStatus.signedOut);
    expect(store.value, isNull);
    expect(
      (await repo.onlineHistory()).first.message,
      'signed out marino (server not reached)',
    );
  });

  test('check proves the session and picks up a changed profile', () async {
    browserResult = fromBrowser();
    final auth = controller();
    await auth.load();
    await auth.signIn();
    server.profile = {'preferred_username': 'marino', 'name': 'Marinó N.'};
    expect(await auth.check(), isTrue);
    expect(auth.displayName, 'Marinó N.');
    expect(auth.email, isNull);
    expect(server.refreshes, 1);
  });

  test('unsent recordings are counted for the Online tab', () async {
    expect(await repo.unsentCount(), 0);
  });
}
