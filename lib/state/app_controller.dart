import 'dart:async';

import 'package:flutter/widgets.dart';

import '../auth/authorizer.dart';
import '../auth/oidc.dart';
import '../auth/token_store.dart';
import '../data/db.dart';
import '../data/repository.dart';
import '../online/mon_client.dart';
import '../polar/models.dart';
import 'app_settings.dart';
import 'auth_controller.dart';
import 'device_controller.dart';
import 'live_hr.dart';
import 'live_ppi.dart';
import 'online_sync.dart';
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
  late final LiveHrService liveHr;
  late final SyncService sync;

  /// The optional Loria sign-in (Online tab). Only online sync depends on it.
  late final AuthController auth;

  /// Upload of recordings to mon. Does nothing unless somebody is signed in.
  late final OnlineSyncService online;
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
    const oidc = OidcConfig();
    auth = AuthController(
      repo,
      client: OidcClient(oidc),
      store: const SecureTokenStore(),
      authorizer: appAuthAuthorizer(oidc),
    );
    // Reads the settings table and the Keystore; no network. A failure here
    // must never keep the sensor sync from starting.
    try {
      await auth.load();
    } catch (e) {
      await repo.log('warn', 'sign-in state not loaded: $e');
    }
    livePpi = LivePpiService(device.bridge, device, repo, settings);
    liveHr = LiveHrService(device, repo);
    sync = SyncService(device.bridge, device, repo, settings, livePpi, liveHr);
    livePpi.syncBusy = () => sync.isRunning;
    livePpi.liveWanted = () =>
        sync.isLive && sync.liveType == PolarDataType.ppi;
    livePpi.dataChanged = sync.dataChanged;
    liveHr.dataChanged = sync.dataChanged;
    online = OnlineSyncService(repo, auth, MonClient())
      ..dataChanged = sync.dataChanged;
    // New recordings go online as soon as the sensor has handed them over,
    // and whatever is waiting goes when somebody signs in.
    sync.onSyncDone = () => unawaited(online.run(reason: 'after sync'));
    var signedIn = auth.isSignedIn;
    auth.addListener(() {
      if (auth.isSignedIn && !signedIn) {
        unawaited(online.run(reason: 'signed in'));
      }
      signedIn = auth.isSignedIn;
    });
    settings.addListener(notifyListeners);
    sync.addListener(notifyListeners);
    livePpi.addListener(notifyListeners);
    device.addListener(notifyListeners);
    // Live PP intervals only while someone is looking: the sensor cannot
    // stream and record them at once, and an unplanned disconnect in the
    // background would otherwise leave no PPI recording running.
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        final fg = _isForeground(s);
        livePpi.foreground = fg;
        sync.onForeground(fg);
      },
    );
    livePpi.foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
    _ready = true;
    notifyListeners();
    unawaited(sync.applySchedule());
    // Whatever an earlier run left behind (no network, app closed mid-way).
    unawaited(online.run(reason: 'app start'));
    if (settings.isPaired) {
      // Connect, sync, disconnect. The connect attempt gives up after
      // SyncService.connectTimeout when the sensor is off or away.
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
    liveHr.dispose();
    sync.dispose();
    online.dispose();
    auth.dispose();
    super.dispose();
  }
}
