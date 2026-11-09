import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/repository.dart';
import '../polar/models.dart';
import 'app_settings.dart';
import 'device_controller.dart';
import 'sync_service.dart';

/// Owns the database, settings and the sync service. One instance per app,
/// created in `main.dart`, alive for the whole process (the Flutter engine is
/// cached and outlives the Activity).
class AppController extends ChangeNotifier {
  AppController(this.device);

  final DeviceController device;
  late final HeildDb db;
  late final Repository repo;
  late final AppSettings settings;
  late final SyncService sync;

  bool _ready = false;
  bool get isReady => _ready;

  Future<void> init() async {
    if (_ready) return;
    db = await HeildDb.open();
    repo = Repository(db);
    settings = AppSettings(repo);
    await settings.load();
    sync = SyncService(device.bridge, device, repo, settings);
    settings.addListener(notifyListeners);
    sync.addListener(notifyListeners);
    device.addListener(notifyListeners);
    _ready = true;
    notifyListeners();
    if (settings.isPaired && settings.autoSync) {
      // A paired sensor that is already on and in range will not produce a
      // CDM "appeared" event, so start looking for it right away. The SDK's
      // connect waits for the advertisement without a continuous scan.
      unawaited(sync.connectAndSync(reason: 'app start'));
    }
  }

  /// Makes [info] the sensor heild wears: remembers it and connects. The SDK
  /// (FEATURE_COMPANION_DEVICE_MANAGEMENT) shows the Companion Device Manager
  /// dialog on the first connection and observes presence from then on.
  Future<void> pair(PolarDeviceInfo info) async {
    await settings.setPaired(
      deviceId: info.deviceId,
      address: info.address,
      name: info.name,
    );
    await sync.connectAndSync(reason: 'paired');
  }

  Future<void> unpair() async {
    final id = settings.pairedDeviceId;
    await sync.disconnect();
    if (id != null) {
      try {
        await device.bridge.companionRemove(id);
      } catch (_) {}
    }
    await settings.setPaired(deviceId: null, address: null, name: null);
  }

  @override
  void dispose() {
    sync.dispose();
    super.dispose();
  }
}
