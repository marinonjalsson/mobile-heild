import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../polar/models.dart';

/// User settings, persisted in the `settings` table and cached in memory.
class AppSettings extends ChangeNotifier {
  AppSettings(this._repo);

  final Repository _repo;

  String? pairedDeviceId;
  String? pairedAddress;
  String? pairedName;

  /// Types recorded on the sensor.
  Set<PolarDataType> recordTypes = {
    PolarDataType.hr,
    PolarDataType.ppi,
    PolarDataType.acc,
  };
  int accRateHz = 26;
  int accRangeG = 8;

  /// Minutes between "stop, fetch, restart" rounds while connected.
  int rotationMinutes = 60;
  int retentionDays = 30;

  /// Connect and sync whenever the sensor appears.
  bool autoSync = true;

  /// Keep the BLE connection while the sensor is in range (live HR, rotation).
  bool stayConnected = true;

  /// Start a live HR stream after each sync for the dashboard.
  bool liveHr = true;

  /// While the app is open and connected, stream PP intervals to the phone
  /// (pulse quality on the dashboard) instead of recording them on the sensor.
  bool livePpi = true;

  bool get isPaired => pairedDeviceId != null;

  Future<void> load() async {
    pairedDeviceId = await _repo.getSetting('paired_device_id');
    pairedAddress = await _repo.getSetting('paired_address');
    pairedName = await _repo.getSetting('paired_name');
    final types = await _repo.getSetting('record_types');
    if (types != null) {
      recordTypes = (jsonDecode(types) as List)
          .map((e) => PolarDataType.fromWire(e as String))
          .toSet();
    }
    accRateHz = int.tryParse(await _repo.getSetting('acc_rate_hz') ?? '') ?? 26;
    accRangeG = int.tryParse(await _repo.getSetting('acc_range_g') ?? '') ?? 8;
    rotationMinutes =
        int.tryParse(await _repo.getSetting('rotation_minutes') ?? '') ?? 60;
    retentionDays =
        int.tryParse(await _repo.getSetting('retention_days') ?? '') ?? 30;
    autoSync = (await _repo.getSetting('auto_sync') ?? 'true') == 'true';
    stayConnected =
        (await _repo.getSetting('stay_connected') ?? 'true') == 'true';
    liveHr = (await _repo.getSetting('live_hr') ?? 'true') == 'true';
    livePpi = (await _repo.getSetting('live_ppi') ?? 'true') == 'true';
    notifyListeners();
  }

  Future<void> setPaired({
    required String? deviceId,
    required String? address,
    required String? name,
  }) async {
    pairedDeviceId = deviceId;
    pairedAddress = address;
    pairedName = name;
    await _repo.setSetting('paired_device_id', deviceId);
    await _repo.setSetting('paired_address', address);
    await _repo.setSetting('paired_name', name);
    notifyListeners();
  }

  Future<void> setRecordTypes(Set<PolarDataType> types) async {
    recordTypes = types;
    await _repo.setSetting(
      'record_types',
      jsonEncode(types.map((t) => t.wire).toList()),
    );
    notifyListeners();
  }

  Future<void> setAcc({int? rateHz, int? rangeG}) async {
    if (rateHz != null) {
      accRateHz = rateHz;
      await _repo.setSetting('acc_rate_hz', '$rateHz');
    }
    if (rangeG != null) {
      accRangeG = rangeG;
      await _repo.setSetting('acc_range_g', '$rangeG');
    }
    notifyListeners();
  }

  Future<void> setRotationMinutes(int minutes) async {
    rotationMinutes = minutes;
    await _repo.setSetting('rotation_minutes', '$minutes');
    notifyListeners();
  }

  Future<void> setRetentionDays(int days) async {
    retentionDays = days;
    await _repo.setSetting('retention_days', '$days');
    notifyListeners();
  }

  Future<void> setAutoSync(bool v) async {
    autoSync = v;
    await _repo.setSetting('auto_sync', '$v');
    notifyListeners();
  }

  Future<void> setStayConnected(bool v) async {
    stayConnected = v;
    await _repo.setSetting('stay_connected', '$v');
    notifyListeners();
  }

  Future<void> setLiveHr(bool v) async {
    liveHr = v;
    await _repo.setSetting('live_hr', '$v');
    notifyListeners();
  }

  Future<void> setLivePpi(bool v) async {
    livePpi = v;
    await _repo.setSetting('live_ppi', '$v');
    notifyListeners();
  }

  /// The ACC sensor setting to record with.
  SensorSetting accSetting() => SensorSetting({
    SettingType.sampleRate: accRateHz,
    SettingType.range: accRangeG,
    SettingType.resolution: 16,
  });
}
