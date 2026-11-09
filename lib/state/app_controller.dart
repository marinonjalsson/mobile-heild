import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/db.dart';
import '../data/repository.dart';
import '../polar/models.dart';
import 'app_settings.dart';
import 'device_controller.dart';
import 'live_ppi.dart';
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
  late final LivePpiService livePpi;
  late final SyncService sync;
  AppLifecycleListener? _lifecycle;

  bool _ready = false;
  bool get isReady => _ready;

  Future<void> init() async {
    if (_ready) return;
    db = await HeildDb.open();
    repo = Repository(db);
    settings = AppSettings(repo);
    await settings.load();
    if (await repo.getSetting(HeildDb.statsRebuildKey) == '1') {
      final n = await repo.rebuildMinuteStats();
      await repo.setSetting(HeildDb.statsRebuildKey, '0');
      await repo.log('info', 'rebuilt statistics for $n minutes');
    }
    livePpi = LivePpiService(device.bridge, device, repo, settings);
    sync = SyncService(device.bridge, device, repo, settings, livePpi);
    livePpi.syncBusy = () => sync.isRunning;
    settings.addListener(notifyListeners);
    sync.addListener(notifyListeners);
    livePpi.addListener(notifyListeners);
    device.addListener(notifyListeners);
    // Live PP intervals only while someone is looking: the sensor cannot
    // stream and record them at once, and an unplanned disconnect in the
    // background would otherwise leave no PPI recording running.
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) => livePpi.foreground = _isForeground(s),
    );
    livePpi.foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
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

  static bool _isForeground(AppLifecycleState? s) =>
      s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  @override
  void dispose() {
    _lifecycle?.dispose();
    livePpi.dispose();
    sync.dispose();
    super.dispose();
  }
}
