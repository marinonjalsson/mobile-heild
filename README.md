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
