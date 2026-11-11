import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where heild signs in: the Loria Authelia (`web/auth`), client `heild`.
///
/// A public client: authorisation code with PKCE in the system browser, no
/// secret. The endpoints are written out rather than discovered, so nothing
/// here needs a round trip before the first request.
class OidcConfig {
  const OidcConfig({
    this.issuer = 'https://auth.loria.is',
    this.clientId = 'heild',
    this.redirectUrl = 'is.loria.heild:/oauthredirect',
    this.scopes = const [
      'openid',
      'profile',
      'email',
      // So that mon can see the heild_user group when it is shown the access
      // token: it accepts uploads from members only. A session from before
      // this scope was asked for has no groups in it and is refused there
      // until the person signs in again.
      'groups',
      'offline_access',
    ],
  });

  final String issuer;
  final String clientId;

  /// The scheme is the Android application id (`appAuthRedirectScheme` in
  /// `android/app/build.gradle.kts`) and must match the client's
  /// `redirect_uris` in Authelia exactly.
  final String redirectUrl;
  final List<String> scopes;

  String get authorizationEndpoint => '$issuer/api/oidc/authorization';
  String get tokenEndpoint => '$issuer/api/oidc/token';
  String get userInfoEndpoint => '$issuer/api/oidc/userinfo';
  String get revocationEndpoint => '$issuer/api/oidc/revocation';
}

/// What a sign-in or a refresh hands back.
class TokenSet {
  TokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;

  /// Authelia replaces the refresh token every time it is used and refuses
  /// the old one, so this must be stored before anything else happens.
  final String? refreshToken;
  final DateTime expiresAt;
}

/// Who signed in, from the userinfo endpoint. Authelia's ID token carries only
/// an opaque `sub`; the username is `preferred_username` here.
class UserInfo {
  UserInfo({required this.username, this.name, this.email});

  final String username;
  final String? name;
  final String? email;
}

/// The server answered and said no (`error` from RFC 6749 §5.2), or answered
/// with something that is not what the endpoint is supposed to return.
class OidcException implements Exception {
  OidcException(this.error, [this.description, this.statusCode]);

  final String error;
  final String? description;
  final int? statusCode;

  /// The refresh token is gone for good: expired, revoked, or already used.
  /// Nothing but a new sign-in helps.
  bool get isInvalidGrant => error == 'invalid_grant';

  @override
  String toString() => description == null ? error : '$error: $description';
}

/// The token, userinfo and revocation endpoints over plain HTTPS. The browser
/// part of a sign-in is not here (see `authorizer.dart`); everything in this
/// class works headless, which is what a scheduled upload needs.
class OidcClient {
  OidcClient(
    this.config, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final OidcConfig config;
  final Duration timeout;
  final http.Client _http;
  final DateTime Function() _now;

  /// Trades a refresh token for a new access token and a new refresh token.
  Future<TokenSet> refresh(String refreshToken) async {
    final res = await _http
        .post(
          Uri.parse(config.tokenEndpoint),
          body: {
            'grant_type': 'refresh_token',
            'client_id': config.clientId,
            'refresh_token': refreshToken,
          },
        )
        .timeout(timeout);
    final body = _json(res);
    if (res.statusCode != 200) throw _error(res, body);
    final access = body['access_token'];
    if (access is! String || access.isEmpty) {
      throw OidcException('invalid_response', 'no access token', 200);
    }
    final expiresIn = body['expires_in'];
    return TokenSet(
      accessToken: access,
      refreshToken: body['refresh_token'] as String?,
      expiresAt: _now().add(
        Duration(seconds: expiresIn is num ? expiresIn.toInt() : 300),
      ),
    );
  }

  Future<UserInfo> userInfo(String accessToken) async {
    final res = await _http
        .get(
          Uri.parse(config.userInfoEndpoint),
          headers: {'Authorization': 'Bearer $accessToken'},
        )
        .timeout(timeout);
    final body = _json(res);
    if (res.statusCode != 200) throw _error(res, body);
    final username = body['preferred_username'];
    if (username is! String || username.isEmpty) {
      throw OidcException('invalid_response', 'no preferred_username', 200);
    }
    return UserInfo(
      username: username,
      name: body['name'] as String?,
      email: body['email'] as String?,
    );
  }

  /// Tells the server to forget a refresh token (sign-out). RFC 7009: a 200
  /// also for a token it never knew.
  Future<void> revoke(String refreshToken) async {
    final res = await _http
        .post(
          Uri.parse(config.revocationEndpoint),
          body: {
            'client_id': config.clientId,
            'token': refreshToken,
            'token_type_hint': 'refresh_token',
          },
        )
        .timeout(timeout);
    if (res.statusCode != 200) throw _error(res, _json(res));
  }

  static Map<String, Object?> _json(http.Response res) {
    try {
      final v = jsonDecode(utf8.decode(res.bodyBytes));
      if (v is Map<String, Object?>) return v;
    } catch (_) {}
    return const {};
  }

  static OidcException _error(http.Response res, Map<String, Object?> body) =>
      OidcException(
        body['error'] as String? ?? 'http_${res.statusCode}',
        body['error_description'] as String?,
        res.statusCode,
      );
}
