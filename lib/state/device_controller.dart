import 'dart:async';

import 'package:flutter/foundation.dart';

import '../polar/models.dart';
import '../polar/polar_bridge.dart';

enum PolarConnectionState { disconnected, connecting, connected }

/// A running online stream and what it has delivered so far.
class ActiveStream {
  ActiveStream(this.type, this.settings, this.subscription)
    : startedAt = DateTime.now();

  final PolarDataType type;
  final SensorSetting? settings;
  final StreamSubscription<StreamBatch> subscription;
  final DateTime startedAt;

  StreamBatch? latest;
  int batches = 0;
  int samples = 0;
  Object? error;

  double get samplesPerSecond {
    final secs = DateTime.now().difference(startedAt).inMilliseconds / 1000;
    return secs <= 0 ? 0 : samples / secs;
  }
}

/// Connection state of the one device the app works with, plus live streams.
///
/// Device operations that are a single call (time, LED, SDK mode...) go straight
/// to [PolarBridge] from the UI; this class only keeps shared, long-lived state.
class DeviceController extends ChangeNotifier {
  DeviceController(this.bridge) {
    _events = bridge.events.listen(
      _onEvent,
      onError: (Object e) => log('events error: $e'),
    );
  }

  final PolarBridge bridge;
  late final StreamSubscription<PolarEvent> _events;

  String? deviceId;
  PolarDeviceInfo? device;
  PolarConnectionState connection = PolarConnectionState.disconnected;
  DisconnectInfo? lastDisconnect;
  bool blePowered = true;

  final Set<String> featuresReady = {};
  final Set<String> featuresUnavailable = {};
  final Map<String, String> disInfo = {};
  int? batteryLevel;
  String? chargeState;
  HrSample? lastHrNotification;

  final Map<PolarDataType, ActiveStream> streams = {};
  final List<String> eventLog = [];

  bool get isConnected => connection == PolarConnectionState.connected;

  /// Firmware version from the Device Information Service, if received.
  /// Polar reports the device firmware as the DIS *Software revision*
  /// (0x2A28); *Firmware revision* (0x2A26) is the BLE stack version.
  String? get firmwareVersion {
    String? byUuid(String uuid) {
      for (final e in disInfo.entries) {
        if (e.key.toLowerCase().startsWith(uuid)) return e.value;
      }
      return null;
    }

    return byUuid('00002a28') ?? byUuid('00002a26');
  }

  /// Last error of a stream that ended, kept until the type is started again.
  final Map<PolarDataType, Object> streamErrors = {};

  void log(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    eventLog.insert(0, '$t  $line');
    if (eventLog.length > 300) eventLog.removeLast();
    notifyListeners();
  }

  Future<void> connect(String id) async {
    deviceId = id;
    connection = PolarConnectionState.connecting;
    lastDisconnect = null;
    featuresReady.clear();
    featuresUnavailable.clear();
    disInfo.clear();
    batteryLevel = null;
    chargeState = null;
    notifyListeners();
    await bridge.connect(id);
  }

  Future<void> disconnect() async {
    final id = deviceId;
    if (id == null) return;
    await stopAllStreams();
    await bridge.disconnect(id);
  }

  Future<void> startStream(
    PolarDataType type, {
    SensorSetting? settings,
  }) async {
    final id = deviceId;
    if (id == null) return;
    await stopStream(type);
    streamErrors.remove(type);
    late ActiveStream active;
    final sub = bridge
        .startStream(id, type, settings: settings)
        .listen(
          (batch) {
            active.latest = batch;
            active.batches++;
            active.samples += batch.samples.length;
            notifyListeners();
          },
          onError: (Object e) {
            active.error = e;
            streamErrors[type] = e;
            log('${type.label} stream error: $e');
            notifyListeners();
          },
          onDone: () {
            if (streams[type] == active) streams.remove(type);
            log('${type.label} stream ended');
            notifyListeners();
          },
        );
    active = ActiveStream(type, settings, sub);
    streams[type] = active;
    log(
      '${type.label} stream started${settings == null ? '' : ' ($settings)'}',
    );
    notifyListeners();
  }

  Future<void> stopStream(PolarDataType type) async {
    final s = streams.remove(type);
    if (s == null) return;
    await s.subscription.cancel();
    log('${type.label} stream stopped');
    notifyListeners();
  }

  Future<void> stopAllStreams() async {
    for (final t in streams.keys.toList()) {
      await stopStream(t);
    }
  }

  void _onEvent(PolarEvent e) {
    final forUs =
        e.identifier == null ||
        deviceId == null ||
        e.identifier == deviceId ||
        e.identifier == device?.address ||
        e.device?.deviceId == deviceId ||
        e.device?.address == deviceId;
    switch (e.type) {
      case 'blePowerState':
        blePowered = e.raw['powered'] as bool;
        log('Bluetooth ${blePowered ? 'on' : 'off'}');
      case 'deviceConnecting':
        if (forUs) {
          device = e.device;
          connection = PolarConnectionState.connecting;
          log('connecting to ${device?.name}');
        }
      case 'deviceConnected':
        if (forUs) {
          device = e.device;
          deviceId ??= device?.deviceId;
          connection = PolarConnectionState.connected;
          log('connected to ${device?.name}');
        }
      case 'deviceDisconnected':
        if (forUs) {
          connection = PolarConnectionState.disconnected;
          final info = e.raw['info'];
          lastDisconnect = info == null
              ? null
              : DisconnectInfo.fromMap(info as Map<Object?, Object?>);
          for (final s in streams.values) {
            s.subscription.cancel();
          }
          streams.clear();
          featuresReady.clear();
          log(
            'disconnected${lastDisconnect == null ? '' : ': $lastDisconnect'}',
          );
        }
      case 'featureReady':
        if (forUs) {
          featuresReady.add(e.raw['feature'] as String);
          log('feature ready: ${e.raw['feature']}');
        }
      case 'featuresReadiness':
        if (forUs) {
          featuresReady.addAll((e.raw['ready'] as List).cast<String>());
          featuresUnavailable
            ..clear()
            ..addAll((e.raw['unavailable'] as List).cast<String>());
          log(
            'features ready: ${featuresReady.length}, unavailable: ${featuresUnavailable.length}',
          );
        }
      case 'disInformation':
        if (forUs) disInfo[e.raw['key'] as String] = e.raw['value'] as String;
      case 'batteryLevel':
        if (forUs) batteryLevel = e.raw['level'] as int;
      case 'batteryChargingStatus':
        if (forUs) chargeState = e.raw['chargeState'] as String;
      case 'hrNotification':
        if (forUs) {
          lastHrNotification = HrSample.fromMap(
            e.raw['sample'] as Map<Object?, Object?>,
          );
        }
      default:
        log('${e.type}: ${e.raw}');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _events.cancel();
    for (final s in streams.values) {
      s.subscription.cancel();
    }
    super.dispose();
  }
}
