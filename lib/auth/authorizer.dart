import 'package:flutter_appauth/flutter_appauth.dart';

import 'oidc.dart';

/// The interactive half of a sign-in: opens the Authelia portal in the system
/// browser and comes back with tokens, or with null when the person closed
/// the browser. Needs an Activity, so only ever called from the UI.
typedef Authorizer = Future<TokenSet?> Function();

/// Authorisation code + PKCE through AppAuth (a Custom Tab, never a WebView:
/// the password is typed into the browser, not into this app).
Authorizer appAuthAuthorizer(OidcConfig config) => () async {
  const appAuth = FlutterAppAuth();
  try {
    final r = await appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        config.clientId,
        config.redirectUrl,
        serviceConfiguration: AuthorizationServiceConfiguration(
          authorizationEndpoint: config.authorizationEndpoint,
          tokenEndpoint: config.tokenEndpoint,
        ),
        scopes: config.scopes,
      ),
    );
    final access = r.accessToken;
    if (access == null) {
      throw OidcException('invalid_response', 'no access token');
    }
    return TokenSet(
      accessToken: access,
      refreshToken: r.refreshToken,
      expiresAt:
          r.accessTokenExpirationDateTime ??
          DateTime.now().add(const Duration(minutes: 5)),
    );
  } on FlutterAppAuthUserCancelledException {
    return null;
  } on FlutterAppAuthPlatformException catch (e) {
    final d = e.platformErrorDetails;
    throw OidcException(d.error ?? e.code, d.errorDescription ?? e.message);
  }
};
