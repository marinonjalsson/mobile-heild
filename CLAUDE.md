# heild

Flutter app (Android first). Long-term goal: help humans live healthy lives — body, mind, food.
Milestone 1: full control of the Polar Verity Sense via the **official Polar BLE SDK**.
Milestone 2: "wear it, forget it" — the sensor records HR/PPI/ACC on its own (offline recording,
trigger on power-on); Android's Companion Device Manager wakes the app when the sensor is in range;
the app syncs the recordings into SQLite and shows graphs/tables.
Milestone 3 (in progress): optional Loria sign-in (done), then upload of the recordings to `mon` over HTTPS with the
signed-in user's token. MQTT was abandoned (2026-11-11).

## Layout

- `lib/polar/` — Dart side of the SDK bridge. `polar_bridge.dart` (channels), `models.dart`, `packed_recording.dart`
  (typed-array form of a fetched recording), `polar_errors.dart`. No UI here.
- `lib/auth/` — the Loria sign-in, no UI: `oidc.dart` (`OidcConfig`, token/userinfo/revocation over plain HTTPS),
  `authorizer.dart` (the browser part, flutter_appauth), `token_store.dart` (refresh token in the Android Keystore).
- `lib/data/` — SQLite: `db.dart` (schema), `repository.dart` (ingest, minute stats, queries, retention),
  `polar_time.dart` (Polar ns since 2000 → Unix ms, HR/PPI timestamp derivation), `acc_codec.dart` (zlib int16 chunks).
- `lib/state/` — `device_controller.dart` (connection, SDK events, live streams), `app_settings.dart` (settings table),
  `sync_service.dart` (the sync state machine), `live_ppi.dart` / `live_hr.dart` (live streams stored as `live` recordings), `auth_controller.dart` (sign-in state, `accessToken()`), `app_controller.dart` (owns db/settings/sync/auth; global `appController` in `main.dart`).
- `lib/ui/` — `home_page.dart` (Graphs / Device / Table / Online / Settings), `online/online_page.dart` (sign-in, account, history), `viewer/` (`dashboard_page.dart` = the Device tab:
  sensor, sync, details, phone storage; `live_card.dart` the live cards shown on Graphs during a live session (HR card on
  Heart rate, PP-interval card on HRV);
  graphs via fl_chart `chart.dart` — `StatChart` pinch-zooms the time axis
  with `FlTransformationConfig`, two-finger only so the list keeps scrolling; `graphs_page.dart` ranges 1 h/6 h/day/week/month,
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
- **No standing connection** (decided 2026-11-10 after a day of drain): every trigger connects, syncs and disconnects
  (`SyncService._rest`: auto-reconnect off, disconnect, `serviceIdle`). Triggers: the schedule (Kotlin `SyncSchedule`
  alarm, `setAndAllowWhileIdle`, re-armed on each fire and after boot; `HeildService` started with the `sync` extra sends
  the app event `scheduledSync` to Dart), app start, app coming to the foreground with data older than 30 min, "Sync now",
  and optionally presence (`autoSync`, off by default). A connect attempt gives up after `connectTimeout` (90 s) so the
  SDK never scans for an absent sensor for long.
- One sync round (`SyncService._run`): set clock → stop running recordings → list → fetch packed → `Repository.storeRecording` →
  delete on sensor → ensure trigger + restart recordings → retention. Never fatal: errors are logged to `sync_log` and
  retried on the next trigger.
- Live session (`SyncService.startLive(type)/setLiveType/stopLive`, "Live"/"Stop" in the Graphs type row): the only way to
  stay connected. The stream follows the selected graph (`liveType`): Heart rate → HR stream, HRV → PP intervals via
  `LivePpiService.liveWanted`; switching graphs while live switches the stream. **Movement cannot be streamed**: on FW 3.0.16
  an online ACC stream makes the sensor go silent and reboot within seconds (BLE supervision timeout), with or without the
  offline ACC/PPI recordings stopped first (tested 2026-11-10), so Live is greyed out there (`SyncService.liveTypes`).
  The session runs until Stop or the app leaves the foreground, then syncs and disconnects. `_ensureLiveStreams` runs once
  per connection (`_liveEnsured`): it logs, logging notifies the device controller, and re-running from that
  notification once looped hundreds of times a second.
- Service protocol (Dart → Kotlin): `serviceStart` before connecting, `serviceNotification(title, text)` on phase changes,
  `serviceIdle` after every disconnect (20 s fallback for disconnects we did not ask for). Kotlin starts the service
  itself on a presence event and on the sync alarm.
- Storage: raw rows for HR/PPI, zlib int16 chunks per minute for ACC, `minute_stats` (per type and minute: n/mean/min/max/extra;
  extra = RMSSD for PPI, std |a| for ACC) feed every graph. Retention deletes recordings older than N days **only if `sent_ms` is set**.
- Timestamps: Polar ns since 2000-01-01 in the sensor's *local* time → `polarNsToUnixMs` subtracts the phone zone offset.
  Offline HR has no stamps (1 Hz from start); PPI accumulates intervals when stamps are 0 (offline PPI stamps from the
  Verity Sense start in 2000 and are ignored).
- Live PPI (`lib/state/live_ppi.dart`): during a live session on the HRV graph in the foreground, `LivePpiService` stops the sensor's
  PPI recording and streams PP intervals instead (the sensor cannot do both); samples are stamped on arrival and stored as a
  `source = 'live'` recording that grows in place (flush every 60 s). Session end → stream stops, PPI recording re-armed.
  `SyncService._ensureRecording` skips PPI while `livePpi.holdsPpi`; `_afterRun` calls `livePpi.reconcile()`. The dashboard's
  pulse state (good/poor/lost) comes from `blockerBit` + `errorEstimate ≤ 30 ms`, never from skin contact (unreliable on this
  sensor). Live HR samples carry nothing but the number, so without PPI the card falls back to "same value for 60 s = held".
- Live HR (`lib/state/live_hr.dart`): `LiveHrService` stamps every live HR sample on arrival and stores the session as a
  `source = 'live'` HR recording: first flush and any flush after a trim rewrite it (`storeRecording` with `sampleTsMs` +
  `replaceId`), every other flush only appends the new samples (`appendHr`). Never rewrite a growing session on every
  flush: that once saturated the DB thread (a cover-during-write loop re-stored 11 k rows every second, 80 % CPU all day). The sensor records HR
  at the same time, so when the sync stores an offline HR recording the repository drops live rows inside its span
  (`_trimLiveHr`, last sample covers its full second) and `SyncService` calls `liveHr.covered(start, end)` so the in-memory
  session forgets them too. Offline always wins; live only fills the time since the last sync.
- Viewers key their queries on `SyncService.dataVersion`, bumped after a sync, a live flush (HR and PPI), a rebuild or a
  delete; `lastSyncAt` is only for display.
- `minute_stats` is a pure function of the raw rows (`_recomputeMinutes`); schema upgrades that change a statistic set
  `HeildDb.statsRebuildKey` and the app controller rebuilds at start.

## Sign-in & online sync (milestone 3)

- **Optional.** The app never waits for a sign-in; only online sync needs one. Nothing in `SyncService` (the sensor
  sync) may depend on `AuthController`.
- Identity provider: the Loria Authelia at `https://auth.loria.is` (repo `web/auth`), OIDC client `heild`: public,
  PKCE S256, redirect `is.loria.heild:/oauthredirect`, scopes `openid profile email offline_access`. The redirect scheme
  is in three places that must agree: `OidcConfig.redirectUrl`, `appAuthRedirectScheme` in `android/app/build.gradle.kts`,
  and the client's `redirect_uris` in `web/auth/config/configuration.yml`.
- flutter_appauth is used only for the interactive part (Custom Tab → code → tokens). Refresh, userinfo and revocation
  are plain HTTPS in `OidcClient`, so they run headless (scheduled upload) and are testable with `MockClient`.
- Observed on Authelia 4.39.14 (local run, 2026-11-11): the ID token carries only an opaque `sub`, the username is
  `preferred_username` from **userinfo**; refresh tokens **rotate** and the old one is refused with `invalid_grant`, so
  `AuthController.accessToken()` is single-flight and stores the new refresh token before anything else; the consent page
  shows on every sign-in (Authelia will not remember consent with `offline_access`).
- **`MainActivity` must not have `android:taskAffinity=""`** (the Flutter template adds it). With it the redirect lands
  in a new task, AppAuth's waiting activity is never found and the browser hangs on the consent page with the spinner
  on ACCEPT; Authelia has answered 200 by then, so the server logs look fine (seen and fixed 2026-11-11 on the phone).
- A sign-in that the browser never answers leaves `signingIn` set; `AuthController.cancelSignIn()` (Cancel on the
  Online tab) abandons it, and a session that still arrives afterwards is revoked.
- Lifetimes (Authelia lifespan `app`): access token 1 h, refresh token 90 days, renewed on every use.
- State: refresh token in `SecureTokenStore` (never in SQLite), profile in `settings` (`auth_username`, `auth_name`,
  `auth_email`, `auth_signed_in_ms`, `auth_expired`), access token in memory. `AuthStatus.expired` = the server refused
  the refresh token; the username is kept so the Online tab can ask that person to sign in again. No network is not
  expiry: the session is kept and `accessToken()` returns null with `lastError` set.
- `online_log` (schema v4; kind `auth` | `push`, ok, message) is the history on the Online tab. The upload step writes
  `push` rows and sets `recordings.sent_ms` (which is what retention waits for). `Repository.unsentCount()` is what waits.
- Not built yet: the upload itself. mon's endpoint and how it checks the token are undecided.

## Build / run

- `minSdk 33`, `compileSdk 37` (permission_handler needs 37). JDK 21. Polar SDK 8.5.0 (`8.5.0-java17` exists if D8 complains).
- `flutter analyze && flutter test` (DB tests run on the host via `sqflite_common_ffi`), then `flutter run -d <serial>` or
  `flutter build apk --debug` + `adb install -r`.
- Runtime permissions: `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS` (permission_handler).
  Manifest also declares FOREGROUND_SERVICE(_CONNECTED_DEVICE), companion permissions and REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.

## Out of scope for now

iOS, MQTT (abandoned; upload to mon is HTTPS, see milestone 3), AES-secured recordings, H10/watch-only APIs.
