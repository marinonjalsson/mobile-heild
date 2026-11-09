# heild

Flutter app (Android first). Long-term goal: help humans live healthy lives — body, mind, food.
Milestone 1: full control of the Polar Verity Sense via the **official Polar BLE SDK**.

## Layout

- `lib/polar/` — Dart side of the SDK bridge. `polar_bridge.dart` (channels), `models.dart`, `polar_errors.dart`. No UI here.
- `lib/state/device_controller.dart` — ChangeNotifier with connection state, SDK events, live streams. Single global in `main.dart`.
- `lib/ui/` — `scan_page.dart`, `device_page.dart` (tabs Live / Offline / Device / Advanced / Log), `widgets/common.dart` (runAction, confirmTyped, Section…).
- `android/app/src/main/kotlin/is/loria/heild/polar/` — Kotlin bridge over `com.github.polarofficial:polar-ble-sdk` (JitPack).
  `PolarBridge.kt` method channel `heild/polar`; `PolarEvents.kt` → EventChannel `heild/polar/events`;
  `StreamChannels.kt` → one EventChannel `heild/polar/stream/<id>` per SDK Flow; `Mappers.kt` model ⇄ Map.

## Bridge conventions

- Every SDK `suspend fun` = one method; result is a Map/List/primitive, errors come back as `PlatformException(code = Kotlin exception class, message)` → `PolarException` in Dart.
- Every SDK `Flow` = `openStream(id, kind, args)` then listen on the returned channel name; cancelling the Dart subscription cancels the Kotlin Job, which stops the measurement on the device.
- Enum values travel as Kotlin `name`; times as ISO-8601 strings; byte arrays as `Uint8List`.
- Destructive device operations (factory reset, warehouse sleep, hibernate, firmware update, file delete) need a typed confirmation in the UI (`confirmTyped`).
- Kotlin package is `` `is`.loria.heild `` — `is` is a Kotlin keyword, keep the backticks.

## Build / run

- `minSdk 33`, `compileSdk 37` (permission_handler needs 37). JDK 21. Polar SDK 8.5.0 (`8.5.0-java17` exists if D8 complains).
- `flutter analyze && flutter test`, then `flutter run -d <serial>` or `flutter build apk --debug` + `adb install -r`.
- Only Bluetooth permissions `BLUETOOTH_SCAN` (neverForLocation) and `BLUETOOTH_CONNECT` are requested (permission_handler).

## Out of scope for now

iOS, persisting/exporting data, background service, charts, H10/watch-only APIs.
