import 'package:flutter/services.dart';

import 'models.dart';

/// The Dart side of `WalkBridge.kt`: the `location` foreground service that
/// delivers GPS fixes between [start] and [stop].
class WalkBridge {
  const WalkBridge();

  static const _methods = MethodChannel('heild/walk');
  static const _events = EventChannel('heild/walk/points');

  /// Starts the service. Throws a [PlatformException] with the code
  /// `NoPreciseLocation` or `LocationOff` when it cannot.
  Future<void> start() => _methods.invokeMethod<void>('start');

  Future<void> stop() => _methods.invokeMethod<void>('stop');

  Future<bool> isRunning() async =>
      await _methods.invokeMethod<bool>('isRunning') ?? false;

  /// Every fix while the service runs, about one a second once GPS has a fix.
  Stream<WalkPoint> points() => _events.receiveBroadcastStream().map(
    (e) => WalkPoint.fromEvent(e as Map<Object?, Object?>),
  );
}
