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

  /// Hours between scheduled syncs (connect, fetch, disconnect); 0 = off.
  int syncEveryHours = 2;
  int retentionDays = 30;

  /// Also connect and sync whenever the sensor comes into range (Companion
  /// Device Manager wake). Off by default: the schedule, opening the app and
  /// "Sync now" are the triggers.
  bool autoSync = false;

  /// While the app is open and connected, stream PP intervals to the phone
  /// (pulse quality on the dashboard) instead of recording them on the sensor.

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
    syncEveryHours =
        int.tryParse(await _repo.getSetting('sync_every_hours') ?? '') ?? 2;
    retentionDays =
        int.tryParse(await _repo.getSetting('retention_days') ?? '') ?? 30;
    autoSync = (await _repo.getSetting('auto_sync') ?? 'false') == 'true';
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

  Future<void> setSyncEveryHours(int hours) async {
    syncEveryHours = hours;
    await _repo.setSetting('sync_every_hours', '$hours');
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

  /// The ACC sensor setting to record with.
  SensorSetting accSetting() => SensorSetting({
    SettingType.sampleRate: accRateHz,
    SettingType.range: accRangeG,
    SettingType.resolution: 16,
  });
}
