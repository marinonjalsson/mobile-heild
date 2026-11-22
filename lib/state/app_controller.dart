import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../auth/authorizer.dart';
import '../auth/oidc.dart';
import '../auth/token_store.dart';
import '../data/db.dart';
import '../data/repository.dart';
import '../online/upload_client.dart';
import '../polar/models.dart';
import '../walk/walk_bridge.dart';
import 'app_settings.dart';
import 'auth_controller.dart';
import 'device_controller.dart';
import 'features.dart';
import 'live_hr.dart';
import 'live_ppi.dart';
import 'online_sync.dart';
import 'sync_service.dart';
import 'walk_recorder.dart';

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

  /// Upload of recordings to the server. Does nothing unless somebody is signed in.
  late final OnlineSyncService online;

  /// GPS recording of walks (Walks tab). Listened to by that tab only: it
  /// notifies on every fix and is not forwarded to this controller.
  late final WalkRecorder walk;
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
    liveHr = LiveHrService(device, repo, enabled: liveEnabled);
    sync = SyncService(device.bridge, device, repo, settings, livePpi, liveHr);
    await sync.loadRecordingStatus();
    livePpi.syncBusy = () => sync.isRunning;
    livePpi.liveWanted = () =>
        liveEnabled && sync.isLive && sync.liveType == PolarDataType.ppi;
    livePpi.dataChanged = sync.dataChanged;
    liveHr.dataChanged = sync.dataChanged;
    online = OnlineSyncService(repo, auth, UploadClient())
      ..dataChanged = sync.dataChanged;
    // New recordings go online once the phone is done with the sensor and
    // has disconnected, never during; the foreground service is held until
    // the upload is over. Whatever is waiting goes when somebody signs in.
    online.sensorBusy = () => !sync.deviceIdle;
    sync.afterDevice = () async {
      if (!auth.isSignedIn) return;
      unawaited(
        device.bridge.serviceNotification(
          'heild · uploading',
          'Sending recordings to the server',
        ),
      );
      await online.run(reason: 'after sync');
    };
    walk = WalkRecorder(const WalkBridge(), repo);
    walk.ensurePermission = () async =>
        (await Permission.locationWhenInUse.request()).isGranted;
    walk.onFinished = () => unawaited(online.run(reason: 'walk finished'));
    try {
      await walk.init();
    } catch (e) {
      await repo.log('warn', 'open walks not closed: $e');
    }
    online.addListener(notifyListeners);
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
    if (settings.isPaired) {
      // Connect, sync, disconnect, and then upload (afterDevice), also when
      // the sensor is not found: the connect attempt gives up after
      // SyncService.connectTimeout.
      unawaited(sync.connectAndSync(reason: 'app start'));
    } else {
      // Whatever an earlier run left behind (no network, app closed mid-way).
      unawaited(online.run(reason: 'app start'));
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
    walk.dispose();
    online.dispose();
    auth.dispose();
    super.dispose();
  }
}
