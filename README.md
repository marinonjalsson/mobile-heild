# heild

A Flutter app on the way to helping people live healthier lives. The first milestone is a
complete control panel for the **Polar Verity Sense** optical heart rate sensor, built on the
official [Polar BLE SDK](https://github.com/polarofficial/polar-ble-sdk) through an in-app Kotlin bridge.

## What it does

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
