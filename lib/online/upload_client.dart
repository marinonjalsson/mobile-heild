import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The server answered and said no. [error] is its short word for why
/// (`invalid_token`, `not_in_group`, `invalid_recording`, …), [message] the
/// sentence to show.
class UploadException implements Exception {
  UploadException(this.status, this.error, this.message);

  final int status;
  final String error;
  final String message;

  /// The token is no good (expired, revoked): refresh and try once more.
  bool get isUnauthorized => status == 401;

  /// Signed in, but not allowed: not in the `heild_user` group.
  bool get isForbidden => status == 403;

  /// The server will never take this recording (a sensor clock that was never set,
  /// a shape it does not know). Retrying sends the same thing again.
  bool get isRejected => status == 400 || status == 413;

  @override
  String toString() => message;
}

/// The upload endpoint of the heild site (`web/sites/heild`, heild.loria.is): one recording per request,
/// the access token in the `Authorization` header. The server asks the sign-in
/// service whose token it is and files the recording under that person.
class UploadClient {
  UploadClient({
    http.Client? client,
    this.baseUrl = 'https://heild.loria.is',
    this.timeout = const Duration(minutes: 2),
  }) : _http = client ?? http.Client();

  final http.Client _http;
  final String baseUrl;

  /// Generous: a day of movement is several megabytes on a phone connection.
  final Duration timeout;

  /// Sends one recording (see `buildUpload`). Returns the number of bytes
  /// sent. Throws [UploadException] when the server refuses, and whatever the HTTP
  /// client throws when the server cannot be reached.
  Future<int> upload(String accessToken, Map<String, Object?> recording) async {
    final bytes = utf8.encode(jsonEncode(recording));
    final res = await _http
        .post(
          Uri.parse('$baseUrl/api/upload'),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: bytes,
        )
        .timeout(timeout);
    if (res.statusCode == 200) return bytes.length;

    // the API's own refusals are JSON with a message. Anything else is nginx or
    // a proxy speaking (502 while the server restarts, 413 for a body too large).
    String error = 'http_${res.statusCode}';
    String message = 'The server answered ${res.statusCode}';
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map<String, Object?>) {
        error = body['error'] as String? ?? error;
        message = body['message'] as String? ?? message;
      }
    } catch (_) {}
    throw UploadException(res.statusCode, error, message);
  }
}
