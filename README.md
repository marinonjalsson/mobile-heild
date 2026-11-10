# heild

A Flutter app on the way to helping people live healthier lives, starting with the
**Polar Verity Sense** optical heart rate sensor and the official
[Polar BLE SDK](https://github.com/polarofficial/polar-ble-sdk) through an in-app Kotlin bridge.

Two milestones are in:

1. a complete **control panel** for the sensor (every SDK feature, under Settings → Device → Control panel);
2. **wear it, forget it**: the sensor records on its own, the phone fetches the data whenever the
   sensor is in range, stores it in SQLite and shows it as graphs and tables.

## Wear it, forget it

- Pair once (Settings → Device → Scan → *Use as my sensor*). Android's Companion Device Manager asks
  to allow the app to access the sensor; after that the system wakes the app whenever the sensor
  is switched on nearby, even when the app has been swiped away.
- The sensor records **heart rate, PP intervals (HRV) and acceleration** into its own memory from
  the moment it is switched on (offline recording, trigger on power-on). Types, ACC rate/range and
  the sync interval are in Settings → Recording.
- Tabs: Graphs · Device · Table · Settings. Graphs opens first: a header per type (Heart rate ·
  Pulse intervals/HRV · Movement), the date window, an action bar (time ranges, Now, Sync)
  and the type row with Live stacked above the navigation bar, and a status line while a sync runs; each
  fetched recording shows up in the chart as it lands. The Device tab shows the sensor's
  connection, sync status, battery, storage, firmware and device information, and the phone's
  storage.
- The phone does **not** stay connected. It connects for a sync on a schedule (every 2 h by
  default, Settings → Recording), when you open the app with data older than 30 min, on *Sync now*,
  and optionally when the sensor comes into range (Settings → Device); then it disconnects and
  rests. A connect attempt gives up after 90 s if the sensor is off or away.
- Each sync: set the clock, stop the running recordings, fetch and store them, delete them from the
  sensor, re-arm the trigger and start recording again. Everything is logged in Settings → Storage →
  Sync log. Errors are retried on the next sync.
- **Live** (in the Graphs type row) is one tap away and follows the graph you are on: on *Heart
  rate* the phone connects and streams the heart rate; on *HRV* it streams the PP intervals
  instead of letting the sensor record them (it cannot do both). Each beat carries a quality flag,
  so the card can say "pulse found / unclear / lost" and show live HRV; the streamed beats are
  stored like any recording (tagged *live*). Switching graphs during a session switches the
  stream. *Stop* or leaving the app ends the session with a sync, and the sensor records PP
  intervals again. Known gap: if the connection drops during a live session, PP intervals resume
  only at the next sync or power-on; heart rate and acceleration are unaffected. Movement has no
  live mode: starting an accelerometer stream on this sensor (firmware 3.0.16) makes it reboot.
- The live heart-rate number alone cannot show whether the sensor still sees your pulse: the Verity
  Sense repeats its last value when it loses it. Without live PP intervals the dashboard treats a
  value unchanged for 60 s as held and says so.
- A foreground-service notification ("heild · …") is shown only while the phone talks to the
  sensor.
- Storage on the phone: raw HR/PPI rows, per-minute compressed ACC chunks, and per-minute stats
  (mean/min/max, RMSSD for PPI, movement = std |a| for ACC) that feed the graphs. Graphs cover
  1 h / 6 h / day / week / month windows; a two-finger pinch zooms the time axis further (one finger
  scrolls the page), and the time labels tighten as you zoom. During a live session the heart
  rate and PP intervals streamed to the phone are stored once a minute, so the charts show them
  right away. The sensor's own HR recording replaces the live copy of the same seconds when it is
  fetched. Recordings older
  than 30 days (configurable) are deleted **only once marked as sent to mon**; until MQTT export
  exists, the mark is a manual toggle on each recording.

Phone setup that helps: allow notifications when asked, and exclude heild from battery
optimisation (Settings → Device offers both). On Samsung also add heild to *Never sleeping apps*.

## Control panel (milestone 1)

- **Scan** for Polar sensors, connect by tap or by device ID, listen to HR broadcasts without connecting.
- **Live**: HR (bpm, RR intervals, contact), PPI, PPG, accelerometer, gyroscope, magnetometer — with
  per-stream sample-rate / range / resolution pickers, including SDK-mode capabilities.
- **Offline**: record ACC/Gyro/Mag/PPG/PPI/HR to the sensor's memory, automatic triggers, optional
  AES secret, list / fetch (with progress) / delete recordings.
- **Device**: battery, firmware and DIS info, RSSI, SDK mode, time get/set, DST, disk space, LED config,
  first-time-use physical data, user device settings, feature configuration (multi-BLE, sensor security),
  sync notifications, data deletion, restart / off / hibernate / factory reset / warehouse sleep.
- **Advanced**: firmware check & update, raw file system browser, device logs and log config,
  telemetry, device-to-host notifications, SDK connection settings (MTU, Polar filter, auto-reconnect).
- **Log**: everything the SDK reported during the session.

## Requirements

Android 13+ (Polar SDK 8.x), Flutter ≥ 3.44, JDK 21. iOS is not set up yet.

## Run

```sh
flutter pub get
flutter analyze && flutter test   # DB tests run on the host via sqflite_common_ffi
flutter run -d <device-serial>
```

## Verified on hardware (2026-11-09)

Polar Verity Sense 24BE2139, firmware 3.0.16, Samsung SM-S911B (Android API 37):
scan/connect, all live streams (HR, PPI, PPG, ACC, Gyro, Mag), SDK mode on/off,
time set/read, disk space, LED config, offline ACC recording round trip
(record → list → fetch → delete), trigger read, firmware check, file list,
device-log export, D2H notifications, cached values.

Known device behaviour:

- A type that is live-streaming cannot be started as an offline recording
  (`ERROR_ALREADY_IN_STATE`); stop the live stream first.
- In SDK mode, ACC at 416 Hz made the sensor go silent and reboot after ~7 s
  (BLE `CONNECTION_TIMEOUT`); SDK mode is cleared by the reboot. 208 Hz works.
- Telemetry (Memfault MDS) is reported unavailable; `getLogConfig` fails with
  `NO_SUCH_FILE_OR_DIRECTORY` until the device has a log config file.
- Firmware update, factory reset, hibernate and warehouse sleep were not run.

Milestone 2 on the same hardware: companion pairing dialog, presence observation, foreground
service start from the background ("Background started FGS: Allowed"), auto-connect on app start,
sync round of HR + PPI + ACC (26 Hz ±8 g), dashboard / graphs / table.

- Offline ACC needs the CHANNELS setting as well as rate/range/resolution, otherwise the sensor
  answers `ERROR_INVALID_NUMBER_OF_CHANNELS` for both the recording and the trigger.
- Offline PPI samples carry device timestamps that count correctly but start in July 2000; the app
  ignores them and accumulates the intervals from the recording start instead.
- The SDK registers one presence listener per connection, so each appearance is reported several
  times; the app de-duplicates them within 15 s.
