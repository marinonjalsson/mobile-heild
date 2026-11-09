import 'package:flutter/services.dart';

/// An error raised by the Polar BLE SDK, carried over the platform channel.
///
/// [code] is the Kotlin exception class name (for example `PolarDeviceNotConnected`,
/// `PolarOperationNotSupported`, `PolarBleSdkInternalException`).
class PolarException implements Exception {
  PolarException(this.code, this.message);

  factory PolarException.fromPlatform(PlatformException e) =>
      PolarException(e.code, e.message ?? e.code);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Runs [body] and rethrows platform errors as [PolarException].
Future<T> polarCall<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on PlatformException catch (e) {
    throw PolarException.fromPlatform(e);
  }
}
