import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/authorizer.dart';
import '../auth/oidc.dart';
import '../auth/token_store.dart';
import '../data/repository.dart';

enum AuthStatus {
  /// Nobody is signed in. The app works; online sync does not.
  signedOut,

  signedIn,

  /// Somebody was signed in and the server no longer accepts the refresh
  /// token (ninety days away, revoked, password changed). The username is
  /// kept so the page can say who needs to sign in again.
  expired,
}

/// The Loria sign-in. Optional: only online sync needs it, and nothing else
/// in the app ever waits for it.
///
/// The refresh token is in the [TokenStore] (Android Keystore), the profile in
/// the `settings` table, the access token in memory only.
class AuthController extends ChangeNotifier {
  AuthController(
    this._repo, {
    required this.client,
    required this._store,
    required this._authorizer,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Repository _repo;
  final OidcClient client;
  final TokenStore _store;
  final Authorizer _authorizer;
  final DateTime Function() _now;

  AuthStatus status = AuthStatus.signedOut;
  String? username;
  String? displayName;
  String? email;
  DateTime? signedInAt;

  /// A sign-in, sign-out or check is running (the page disables its buttons).
  bool busy = false;

  /// [busy] because a sign-in is waiting for the browser; see [cancelSignIn].
  bool signingIn = false;
  int _signInRun = 0;

  /// Why the last sign-in or check did not work, for the page. Cleared by the
  /// next one that does.
  String? lastError;

  /// Bumped with every row this controller adds to `online_log`; the Online
  /// tab re-reads its history when it changes, and not on every rebuild.
  int historyVersion = 0;

  String? _accessToken;
  DateTime? _accessExpires;
  Future<String?>? _refreshing;

  bool get isSignedIn => status == AuthStatus.signedIn;

  Future<void> load() async {
    username = await _repo.getSetting('auth_username');
    displayName = await _repo.getSetting('auth_name');
    email = await _repo.getSetting('auth_email');
    final at = int.tryParse(await _repo.getSetting('auth_signed_in_ms') ?? '');
    signedInAt = at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
    if (username == null) {
      status = AuthStatus.signedOut;
    } else if (await _repo.getSetting('auth_expired') == '1' ||
        await _store.read() == null) {
      status = AuthStatus.expired;
    } else {
      status = AuthStatus.signedIn;
    }
    notifyListeners();
  }

  /// Opens the portal in the browser. Returns true when somebody is signed in
  /// afterwards; false when they closed the browser or it failed
  /// ([lastError] says which).
  Future<bool> signIn() async {
    if (busy) return false;
    final run = ++_signInRun;
    busy = true;
    signingIn = true;
    lastError = null;
    notifyListeners();
    try {
      final tokens = await _authorizer();
      if (run != _signInRun) {
        // Cancelled here while the browser was still open, and then finished
        // there anyway. Nobody is waiting for this session: give it back.
        final late = tokens?.refreshToken;
        if (late != null) unawaited(client.revoke(late).catchError((_) {}));
        return false;
      }
      if (tokens == null) return false; // closed the browser
      final refresh = tokens.refreshToken;
      if (refresh == null) {
        throw OidcException(
          'invalid_response',
          'the server gave no refresh token (offline_access not granted)',
        );
      }
      final info = await client.userInfo(tokens.accessToken);
      await _store.write(refresh);
      _accessToken = tokens.accessToken;
      _accessExpires = tokens.expiresAt;
      await _saveProfile(info, signedIn: _now());
      await _repo.setSetting('auth_expired', null);
      status = AuthStatus.signedIn;
      await _log('auth', 'signed in as ${info.username}');
      return true;
    } catch (e) {
      if (run != _signInRun) return false;
      lastError = _describe(e);
      await _log('auth', 'sign-in failed: $lastError', ok: false);
      return false;
    } finally {
      if (run == _signInRun) {
        busy = false;
        signingIn = false;
        notifyListeners();
      }
    }
  }

  /// Gives up on a sign-in that is waiting for the browser. The browser part
  /// does not always answer (the tab can be swiped away with the app, or the
  /// redirect can fail to come back), and without this the button would stay
  /// disabled until the app is killed.
  void cancelSignIn() {
    if (!signingIn) return;
    _signInRun++;
    busy = false;
    signingIn = false;
    notifyListeners();
  }

  /// Forgets the session here and asks the server to forget it too. The local
  /// part always happens; the server part is best effort (no network → the
  /// refresh token simply expires unused).
  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      final who = username;
      final refresh = await _store.read();
      var revoked = false;
      if (refresh != null) {
        try {
          await client.revoke(refresh);
          revoked = true;
        } catch (_) {}
      }
      await _forget();
      status = AuthStatus.signedOut;
      lastError = null;
      await _log(
        'auth',
        'signed out${who == null ? '' : ' $who'}'
            '${refresh != null && !revoked ? ' (server not reached)' : ''}',
      );
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// A token to send with a request, refreshed when the cached one is about
  /// to run out. Null when nobody is signed in, when the server refused the
  /// refresh (status becomes [AuthStatus.expired]) or when it could not be
  /// reached ([lastError] is set, the session is kept and the next call tries
  /// again).
  ///
  /// Single flight: Authelia replaces the refresh token on every use and
  /// refuses the old one, so two refreshes at once would sign the app out.
  Future<String?> accessToken({bool forceRefresh = false}) {
    if (status != AuthStatus.signedIn) return Future.value();
    final exp = _accessExpires;
    if (!forceRefresh &&
        _accessToken != null &&
        exp != null &&
        exp.isAfter(_now().add(const Duration(seconds: 60)))) {
      return Future.value(_accessToken);
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh() async {
    final refresh = await _store.read();
    if (refresh == null) {
      await _expire('no stored session');
      return null;
    }
    try {
      final tokens = await client.refresh(refresh);
      // First, before anything can fail: the old token is already dead.
      final next = tokens.refreshToken;
      if (next != null) await _store.write(next);
      _accessToken = tokens.accessToken;
      _accessExpires = tokens.expiresAt;
      if (lastError != null) {
        lastError = null;
        notifyListeners();
      }
      return tokens.accessToken;
    } on OidcException catch (e) {
      if (e.isInvalidGrant) {
        await _expire('the server no longer accepts this sign-in');
      } else {
        lastError = _describe(e);
        notifyListeners();
      }
      return null;
    } catch (e) {
      // No network, timeout. The session is fine; try again next time.
      lastError = _describe(e);
      notifyListeners();
      return null;
    }
  }

  /// Proves the session still works end to end (refresh + userinfo) and picks
  /// up a changed name or address. For the "Check sign-in" button.
  Future<bool> check() async {
    if (busy || status != AuthStatus.signedIn) return false;
    busy = true;
    notifyListeners();
    try {
      final token = await accessToken(forceRefresh: true);
      if (token == null) return false;
      final info = await client.userInfo(token);
      await _saveProfile(info);
      lastError = null;
      await _log('auth', 'sign-in checked: ${info.username}');
      return true;
    } catch (e) {
      lastError = _describe(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _saveProfile(UserInfo info, {DateTime? signedIn}) async {
    username = info.username;
    displayName = info.name;
    email = info.email;
    await _repo.setSetting('auth_username', username);
    await _repo.setSetting('auth_name', displayName);
    await _repo.setSetting('auth_email', email);
    if (signedIn != null) {
      signedInAt = signedIn;
      await _repo.setSetting(
        'auth_signed_in_ms',
        '${signedIn.millisecondsSinceEpoch}',
      );
    }
  }

  Future<void> _expire(String why) async {
    _accessToken = null;
    _accessExpires = null;
    await _store.clear();
    await _repo.setSetting('auth_expired', '1');
    status = AuthStatus.expired;
    lastError = null;
    await _log('auth', 'signed out: $why', ok: false);
    notifyListeners();
  }

  Future<void> _forget() async {
    _accessToken = null;
    _accessExpires = null;
    username = null;
    displayName = null;
    email = null;
    signedInAt = null;
    await _store.clear();
    for (final k in const [
      'auth_username',
      'auth_name',
      'auth_email',
      'auth_signed_in_ms',
      'auth_expired',
    ]) {
      await _repo.setSetting(k, null);
    }
  }

  Future<void> _log(String kind, String message, {bool ok = true}) async {
    await _repo.onlineLog(kind, message, ok: ok);
    historyVersion++;
  }

  static String _describe(Object e) => switch (e) {
    OidcException() => e.toString(),
    TimeoutException() => 'the sign-in server did not answer',
    _ => e.toString(),
  };
}
