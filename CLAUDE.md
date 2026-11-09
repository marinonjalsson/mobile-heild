# heild

Flutter app (Android first). Long-term goal: help humans live healthy lives — body, mind, food.
Milestone 1: full control of the Polar Verity Sense via the **official Polar BLE SDK**.
Milestone 2: "wear it, forget it" — the sensor records HR/PPI/ACC on its own (offline recording,
trigger on power-on); Android's Companion Device Manager wakes the app when the sensor is in range;
the app syncs the recordings into SQLite and shows graphs/tables. MQTT to `mon` comes later.

## Layout

- `lib/polar/` — Dart side of the SDK bridge. `polar_bridge.dart` (channels), `models.dart`, `packed_recording.dart`
  (typed-array form of a fetched recording), `polar_errors.dart`. No UI here.
- `lib/data/` — SQLite: `db.dart` (schema), `repository.dart` (ingest, minute stats, queries, retention),
  `polar_time.dart` (Polar ns since 2000 → Unix ms, HR/PPI timestamp derivation), `acc_codec.dart` (zlib int16 chunks).
- `lib/state/` — `device_controller.dart` (connection, SDK events, live streams), `app_settings.dart` (settings table),
  `sync_service.dart` (the sync state machine), `app_controller.dart` (owns db/settings/sync; global `appController` in `main.dart`).
- `lib/ui/` — `home_page.dart` (Dashboard / Graphs / Table / Settings), `viewer/` (dashboard, graphs via fl_chart `chart.dart`,
  table + recording detail), `settings/` (settings, device settings), and the milestone-1 control panel:
  `scan_page.dart`, `device_page.dart` (tabs Live / Offline / Device / Advanced / Log), `widgets/common.dart`.
- `android/app/src/main/kotlin/is/loria/heild/`:
  - `polar/` — Kotlin bridge over `com.github.polarofficial:polar-ble-sdk` (JitPack). `PolarHolder.kt` process-wide SDK instance;
    `PolarBridge.kt` method channel `heild/polar`; `PolarEvents.kt` → EventChannel `heild/polar/events`;
    `StreamChannels.kt` → one EventChannel `heild/polar/stream/<id>` per SDK Flow; `Mappers.kt` model ⇄ Map.
  - `HeildApp.kt` — Application; `EngineHolder` creates the ONE cached FlutterEngine at process start (Dart runs headless too);
    `MainActivity` attaches to it (`provideFlutterEngine`, never destroys it).
  - `service/HeildService.kt` — `connectedDevice` foreground service while talking to the sensor.
  - `companion/DevicePresenceService.kt` — subclass of the SDK's `PolarCompanionDeviceServiceBase`; replaces the SDK's own
    service in the manifest (`tools:node="remove"`), starts engine + foreground service, then lets the SDK deliver
    `companionDeviceAppeared` to Dart.

## Bridge conventions

- Every SDK `suspend fun` = one method; result is a Map/List/primitive, errors come back as `PlatformException(code = Kotlin exception class, message)` → `PolarException` in Dart.
- Every SDK `Flow` = `openStream(id, kind, args)` then listen on the returned channel name; cancelling the Dart subscription cancels the Kotlin Job, which stops the measurement on the device.
- Enum values travel as Kotlin `name`; times as ISO-8601 strings; byte arrays as `Uint8List`.
- Destructive device operations (factory reset, warehouse sleep, hibernate, firmware update, file delete) need a typed confirmation in the UI (`confirmTyped`).
- Kotlin package is `` `is`.loria.heild `` — `is` is a Kotlin keyword, keep the backticks.
- Offline recordings are fetched with stream kind `offlineRecordPacked` (typed arrays), never the per-sample Map path, when storing.

## Sync & background (milestone 2)

- Sensor side: `FEATURE_COMPANION_DEVICE_MANAGEMENT` is on, so the SDK runs the Companion Device Manager association on the
  first `connectToDevice` (system dialog) and observes presence afterwards. Trigger `TRIGGER_SYSTEM_START` records the configured
  types whenever the sensor is switched on. HR is the only type that can be live-streamed while also recorded.
- One sync round (`SyncService._run`): set clock → stop running recordings → list → fetch packed → `Repository.storeRecording` →
  delete on sensor → ensure trigger + restart recordings → live HR → retention. Triggered by presence, app start, "Sync now",
  rotation timer while connected. Never fatal: errors are logged to `sync_log` and retried on the next trigger.
- Service protocol (Dart → Kotlin): `serviceStart` before connecting, `serviceNotification(title, text)` on phase changes,
  `serviceIdle` when disconnected with nothing pending (2-min grace). Kotlin starts the service itself on a presence event.
- Storage: raw rows for HR/PPI, zlib int16 chunks per minute for ACC, `minute_stats` (per type and minute: n/mean/min/max/extra;
  extra = RMSSD for PPI, std |a| for ACC) feed every graph. Retention deletes recordings older than N days **only if `sent_ms` is set**.
- Timestamps: Polar ns since 2000-01-01 in the sensor's *local* time → `polarNsToUnixMs` subtracts the phone zone offset.
  Offline HR has no stamps (1 Hz from start); PPI accumulates intervals when stamps are 0 (offline PPI stamps from the
  Verity Sense start in 2000 and are ignored).
- Live PPI (`lib/state/live_ppi.dart`): while the app is in the foreground and connected, `LivePpiService` stops the sensor's
  PPI recording and streams PP intervals instead (the sensor cannot do both); samples are stamped on arrival and stored as a
  `source = 'live'` recording that grows in place (flush every 60 s). Background → stream stops, PPI recording re-armed.
  `SyncService._ensureRecording` skips PPI while `livePpi.holdsPpi`; `_afterRun` calls `livePpi.reconcile()`. The dashboard's
  pulse state (good/poor/lost) comes from `blockerBit` + `errorEstimate ≤ 30 ms`, never from skin contact (unreliable on this
  sensor). Live HR samples carry nothing but the number, so without PPI the card falls back to "same value for 60 s = held".
- `minute_stats` is a pure function of the raw rows (`_recomputeMinutes`); schema upgrades that change a statistic set
  `HeildDb.statsRebuildKey` and the app controller rebuilds at start.

## Build / run

- `minSdk 33`, `compileSdk 37` (permission_handler needs 37). JDK 21. Polar SDK 8.5.0 (`8.5.0-java17` exists if D8 complains).
- `flutter analyze && flutter test` (DB tests run on the host via `sqflite_common_ffi`), then `flutter run -d <serial>` or
  `flutter build apk --debug` + `adb install -r`.
- Runtime permissions: `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS` (permission_handler).
  Manifest also declares FOREGROUND_SERVICE(_CONNECTED_DEVICE), companion permissions and REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.

## Out of scope for now

iOS, MQTT/export to mon (planned next), AES-secured recordings, H10/watch-only APIs.
