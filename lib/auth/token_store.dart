import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the refresh token lives between runs. The access token is never
/// stored: it lasts an hour and a refresh makes a new one.
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String refreshToken);
  Future<void> clear();
}

/// Encrypted with a key in the Android Keystore, not in SQLite: the database
/// is a file that gets copied around (backups, `adb pull` while debugging) and
/// a refresh token is ninety days of being that person.
class SecureTokenStore implements TokenStore {
  const SecureTokenStore();

  static const _storage = FlutterSecureStorage();
  static const _key = 'auth_refresh_token';

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      // A Keystore key that no longer decrypts (restore onto another phone).
      // The token is unreadable either way: same as not signed in.
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(String refreshToken) =>
      _storage.write(key: _key, value: refreshToken);

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

/// For tests.
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String refreshToken) async => value = refreshToken;

  @override
  Future<void> clear() async => value = null;
}
