import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';
import 'packed_recording.dart';
import 'polar_errors.dart';

/// Dart side of the Polar BLE SDK bridge.
///
/// One method on the `heild/polar` channel per SDK call. SDK `Flow`s are opened
/// with [_openStream], which asks Kotlin to register an EventChannel for a fresh id
/// and returns a broadcast [Stream]; cancelling the subscription stops the Flow on
/// the native side (and therefore the measurement on the device).
class PolarBridge {
  PolarBridge._();

  static final PolarBridge instance = PolarBridge._();

  static const _methods = MethodChannel('heild/polar');
  static const _eventsChannel = EventChannel('heild/polar/events');

  int _nextStreamId = 0;

  /// SDK callback events (connection, battery, DIS info, feature readiness...).
  late final Stream<PolarEvent> events = _eventsChannel
      .receiveBroadcastStream()
      .map((e) => PolarEvent.fromMap(e as Map<Object?, Object?>))
      .asBroadcastStream();

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) =>
      polarCall(() => _methods.invokeMethod<T>(method, args));

  Future<Map<Object?, Object?>> _callMap(
    String method, [
    Map<String, Object?> args = const {},
  ]) async => (await _call<Map<Object?, Object?>>(method, args))!;

  Future<List<String>> _callStrings(
    String method, [
    Map<String, Object?> args = const {},
  ]) async => (await _call<List<Object?>>(method, args))!.cast<String>();

  /// Opens a native Flow as a Dart stream. The Flow starts when the stream is
  /// listened to and stops when the subscription is cancelled.
  Stream<T> _openStream<T>(
    String kind,
    Map<String, Object?> args,
    T Function(Object? event) decode,
  ) {
    final id = 's${_nextStreamId++}';
    late StreamController<T> controller;
    StreamSubscription<Object?>? sub;

    controller = StreamController<T>(
      onListen: () async {
        try {
          final name = await _call<String>('openStream', {
            'id': id,
            'kind': kind,
            ...args,
          });
          sub = EventChannel(name!).receiveBroadcastStream().listen(
            (e) => controller.add(decode(e)),
            onError: (Object e, StackTrace st) {
              controller.addError(
                e is PlatformException ? PolarException.fromPlatform(e) : e,
                st,
              );
            },
            onDone: controller.close,
          );
        } on PolarException catch (e, st) {
          controller.addError(e, st);
          await controller.close();
        }
      },
      onCancel: () async {
        await sub?.cancel();
        await _call<void>('closeStream', {'id': id});
      },
    );
    return controller.stream;
  }

  // ---- core -----------------------------------------------------------------

  Future<String> versionInfo() async => (await _call<String>('versionInfo'))!;

  Stream<PolarDeviceInfo> search({String namePrefix = 'Polar'}) => _openStream(
    'search',
    {'namePrefix': namePrefix},
    (e) => PolarDeviceInfo.fromMap(e as Map<Object?, Object?>),
  );

  Future<void> connect(String identifier) =>
      _call<void>('connectToDevice', {'identifier': identifier});
  Future<void> disconnect(String identifier) =>
      _call<void>('disconnectFromDevice', {'identifier': identifier});
  Future<void> waitForConnection(String identifier) =>
      _call<void>('waitForConnection', {'identifier': identifier});
  Future<void> setPolarFilter(bool enable) =>
      _call<void>('setPolarFilter', {'enable': enable});
  Future<void> setAutomaticReconnection(bool enable) =>
      _call<void>('setAutomaticReconnection', {'enable': enable});
  Future<void> setMtu(int mtu) => _call<void>('setMtu', {'mtu': mtu});
  Future<void> cleanup() => _call<void>('cleanup');
  Future<void> foregroundEntered() => _call<void>('foregroundEntered');
  Future<bool> isFeatureReady(String identifier, String feature) async =>
      (await _call<bool>('isFeatureReady', {
        'identifier': identifier,
        'feature': feature,
      }))!;
  Future<String> getDeviceName(String identifier) async =>
      (await _call<String>('getDeviceName', {'identifier': identifier}))!;
  Future<int> getBatteryLevel(String identifier) async =>
      (await _call<int>('getBatteryLevel', {'identifier': identifier}))!;
  Future<String> getChargerState(String identifier) async =>
      (await _call<String>('getChargerState', {'identifier': identifier}))!;
  Future<int> getRssi(String identifier) async =>
      (await _call<int>('getRSSIValue', {'identifier': identifier}))!;
  Future<Map<Object?, Object?>> checkIfDisconnectedDueRemovedPairing(
    String identifier,
  ) => _callMap('checkIfDeviceDisconnectedDueRemovedPairing', {
    'identifier': identifier,
  });

  // ---- app service & companion device (heild's own Kotlin, not SDK) ---------

  /// Starts (or keeps) the connectedDevice foreground service so the Dart side
  /// survives the Activity going away. Idempotent.
  Future<void> serviceStart() => _call<void>('serviceStart');

  /// Tells the foreground service nothing is pending; it stops itself.
  Future<void> serviceIdle() => _call<void>('serviceIdle');

  Future<void> serviceNotification(String title, String text) =>
      _call<void>('serviceNotification', {'title': title, 'text': text});

  /// Arms the scheduled sync alarm every [hours] hours (0 switches it off).
  /// When it fires, Kotlin starts the service and sends `scheduledSync`.
  Future<void> scheduleSync(int hours) =>
      _call<void>('scheduleSync', {'hours': hours});

  /// Debug: fires the sync alarm once after [seconds].
  Future<void> scheduleSyncIn(int seconds) =>
      _call<void>('scheduleSyncIn', {'seconds': seconds});

  /// BT addresses the Companion Device Manager has associated with this app.
  Future<List<String>> companionAssociatedAddresses() =>
      _callStrings('companionAssociatedAddresses');

  Future<bool> companionIsAssociated(String identifier) async =>
      (await _call<bool>('companionIsAssociated', {'identifier': identifier}))!;

  Future<void> companionRemove(String identifier) =>
      _call<void>('companionRemove', {'identifier': identifier});

  /// Opens the system dialog that lets the app run in the background as a
  /// companion app. Needs the Activity; false when none is attached.
  Future<bool> companionRequestBackgroundPrivilege() async =>
      (await _call<bool>('companionRequestBackgroundPrivilege')) ?? false;

  Future<bool> isIgnoringBatteryOptimizations() async =>
      (await _call<bool>('isIgnoringBatteryOptimizations')) ?? false;

  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<void>('requestIgnoreBatteryOptimizations');

  // ---- online streaming -----------------------------------------------------

  Future<List<PolarDataType>> availableOnlineStreamDataTypes(
    String identifier,
  ) async => (await _callStrings('getAvailableOnlineStreamDataTypes', {
    'identifier': identifier,
  })).map(PolarDataType.fromWire).toList();

  Future<List<PolarDataType>> availableHrServiceDataTypes(
    String identifier,
  ) async => (await _callStrings('getAvailableHRServiceDataTypes', {
    'identifier': identifier,
  })).map(PolarDataType.fromWire).toList();

  Future<SensorSettingOptions> requestStreamSettings(
    String identifier,
    PolarDataType type,
  ) async => SensorSettingOptions.fromMap(
    await _callMap('requestStreamSettings', {
      'identifier': identifier,
      'dataType': type.wire,
    }),
  );

  Future<SensorSettingOptions> requestFullStreamSettings(
    String identifier,
    PolarDataType type,
  ) async => SensorSettingOptions.fromMap(
    await _callMap('requestFullStreamSettings', {
      'identifier': identifier,
      'dataType': type.wire,
    }),
  );

  Future<void> stopHrStreaming(String identifier) =>
      _call<void>('stopHrStreaming', {'identifier': identifier});

  /// Starts an online stream of [type]. [settings] is required except for HR and PPI.
  Stream<StreamBatch> startStream(
    String identifier,
    PolarDataType type, {
    SensorSetting? settings,
  }) => _openStream(type.streamKind, {
    'identifier': identifier,
    if (settings != null) 'settings': settings.toMap(),
  }, (e) => StreamBatch.fromMap(e as Map<Object?, Object?>));

  /// Heart rate from BLE advertisements, no connection needed.
  Stream<HrBroadcast> hrBroadcasts({Set<String>? identifiers}) => _openStream(
    'hrBroadcast',
    {'identifiers': identifiers?.toList()},
    (e) => HrBroadcast.fromMap(e as Map<Object?, Object?>),
  );

  // ---- offline recording ----------------------------------------------------

  Future<List<PolarDataType>> availableOfflineRecordingDataTypes(
    String identifier,
  ) async => (await _callStrings('getAvailableOfflineRecordingDataTypes', {
    'identifier': identifier,
  })).map(PolarDataType.fromWire).toList();

  Future<SensorSettingOptions> requestOfflineRecordingSettings(
    String identifier,
    PolarDataType type,
  ) async => SensorSettingOptions.fromMap(
    await _callMap('requestOfflineRecordingSettings', {
      'identifier': identifier,
      'dataType': type.wire,
    }),
  );

  Future<SensorSettingOptions> requestFullOfflineRecordingSettings(
    String identifier,
    PolarDataType type,
  ) async => SensorSettingOptions.fromMap(
    await _callMap('requestFullOfflineRecordingSettings', {
      'identifier': identifier,
      'dataType': type.wire,
    }),
  );

  Future<List<PolarDataType>> offlineRecordingStatus(String identifier) async =>
      (await _callStrings('getOfflineRecordingStatus', {
        'identifier': identifier,
      })).map(PolarDataType.fromWire).toList();

  Future<void> startOfflineRecording(
    String identifier,
    PolarDataType type, {
    SensorSetting? settings,
    String? secretHex,
  }) => _call<void>('startOfflineRecording', {
    'identifier': identifier,
    'dataType': type.wire,
    'settings': settings?.toMap(),
    'secret': secretHex,
  });

  Future<void> stopOfflineRecording(String identifier, PolarDataType type) =>
      _call<void>('stopOfflineRecording', {
        'identifier': identifier,
        'dataType': type.wire,
      });

  Stream<OfflineRecordingEntry> listOfflineRecordings(String identifier) =>
      _openStream('listOfflineRecordings', {
        'identifier': identifier,
      }, (e) => OfflineRecordingEntry.fromMap(e as Map<Object?, Object?>));

  Stream<OfflineFetchEvent> fetchOfflineRecording(
    String identifier,
    OfflineRecordingEntry entry, {
    String? secretHex,
  }) => _openStream('offlineRecordWithProgress', {
    'identifier': identifier,
    'entry': entry.toMap(),
    'secret': secretHex,
  }, (e) => OfflineFetchEvent.fromMap(e as Map<Object?, Object?>));

  /// Like [fetchOfflineRecording] but the completion carries every sample as
  /// typed arrays, suitable for storing (see [PackedRecording]).
  Stream<PackedFetchEvent> fetchOfflineRecordingPacked(
    String identifier,
    OfflineRecordingEntry entry, {
    String? secretHex,
  }) => _openStream('offlineRecordPacked', {
    'identifier': identifier,
    'entry': entry.toMap(),
    'secret': secretHex,
  }, (e) => PackedFetchEvent.fromMap(e as Map<Object?, Object?>));

  Future<void> removeOfflineRecord(
    String identifier,
    OfflineRecordingEntry entry,
  ) => _call<void>('removeOfflineRecord', {
    'identifier': identifier,
    'entry': entry.toMap(),
  });

  Future<void> setOfflineRecordingTrigger(
    String identifier,
    OfflineRecordingTrigger trigger, {
    String? secretHex,
  }) => _call<void>('setOfflineRecordingTrigger', {
    'identifier': identifier,
    'trigger': trigger.toMap(),
    'secret': secretHex,
  });

  Future<OfflineRecordingTrigger> offlineRecordingTriggerSetup(
    String identifier,
  ) async => OfflineRecordingTrigger.fromMap(
    await _callMap('getOfflineRecordingTriggerSetup', {
      'identifier': identifier,
    }),
  );

  // ---- SDK mode -------------------------------------------------------------

  Future<void> enableSdkMode(String identifier) =>
      _call<void>('enableSDKMode', {'identifier': identifier});
  Future<void> disableSdkMode(String identifier) =>
      _call<void>('disableSDKMode', {'identifier': identifier});
  Future<bool> isSdkModeEnabled(String identifier) async =>
      (await _call<bool>('isSDKModeEnabled', {'identifier': identifier}))!;

  // ---- device management ----------------------------------------------------

  Future<void> setLocalTime(String identifier, DateTime local) => _call<void>(
    'setLocalTime',
    {'identifier': identifier, 'dateTime': local.toIso8601String()},
  );

  Future<DateTime> getLocalTimeWithZone(String identifier) async =>
      DateTime.parse(
        (await _call<String>('getLocalTimeWithZone', {
          'identifier': identifier,
        }))!,
      );

  Future<String> getLocalTimeRaw(String identifier) async =>
      (await _call<String>('getLocalTimeWithZone', {
        'identifier': identifier,
      }))!;

  Future<DiskSpace> getDiskSpace(String identifier) async => DiskSpace.fromMap(
    await _callMap('getDiskSpace', {'identifier': identifier}),
  );

  Future<void> setLedConfig(String identifier, LedConfig config) => _call<void>(
    'setLedConfig',
    {'identifier': identifier, 'config': config.toMap()},
  );

  Future<void> doFactoryReset(String identifier) =>
      _call<void>('doFactoryReset', {'identifier': identifier});
  Future<void> doRestart(String identifier) =>
      _call<void>('doRestart', {'identifier': identifier});
  Future<void> setWarehouseSleep(String identifier) =>
      _call<void>('setWarehouseSleep', {'identifier': identifier});
  Future<void> setHibernateMode(String identifier) =>
      _call<void>('setHibernateMode', {'identifier': identifier});
  Future<void> turnDeviceOff(String identifier) =>
      _call<void>('turnDeviceOff', {'identifier': identifier});

  Future<void> doFirstTimeUse(String identifier, PhysicalConfig config) =>
      _call<void>('doFirstTimeUse', {
        'identifier': identifier,
        'config': config.toMap(),
      });
  Future<bool> isFtuDone(String identifier) async =>
      (await _call<bool>('isFtuDone', {'identifier': identifier}))!;
  Future<PhysicalConfig?> getUserPhysicalConfiguration(
    String identifier,
  ) async {
    final m = await _call<Map<Object?, Object?>>(
      'getUserPhysicalConfiguration',
      {'identifier': identifier},
    );
    return m == null ? null : PhysicalConfig.fromMap(m);
  }

  Future<UserDeviceSettings> getUserDeviceSettings(String identifier) async =>
      UserDeviceSettings.fromMap(
        await _callMap('getUserDeviceSettings', {'identifier': identifier}),
      );
  Future<void> setUserDeviceLocation(String identifier, int location) =>
      _call<void>('setUserDeviceLocation', {
        'identifier': identifier,
        'location': location,
      });
  Future<void> setUsbConnectionMode(String identifier, bool enabled) =>
      _call<void>('setUsbConnectionMode', {
        'identifier': identifier,
        'enabled': enabled,
      });
  Future<void> setAutomaticTrainingDetectionSettings(
    String identifier, {
    required bool mode,
    required int sensitivity,
    required int minimumDuration,
  }) => _call<void>('setAutomaticTrainingDetectionSettings', {
    'identifier': identifier,
    'mode': mode,
    'sensitivity': sensitivity,
    'minimumDuration': minimumDuration,
  });
  Future<void> setDaylightSavingTime(String identifier) =>
      _call<void>('setDaylightSavingTime', {'identifier': identifier});
  Future<void> deleteStoredDeviceData(
    String identifier,
    String storedDataType, {
    DateTime? until,
  }) => _call<void>('deleteStoredDeviceData', {
    'identifier': identifier,
    'storedDataType': storedDataType,
    'until': until?.toIso8601String().substring(0, 10),
  });
  Future<void> setTelemetryEnabled(String identifier, bool enabled) =>
      _call<void>('setTelemetryEnabled', {
        'identifier': identifier,
        'enabled': enabled,
      });
  Future<void> deleteDeviceDateFolders(
    String identifier, {
    DateTime? from,
    DateTime? to,
  }) => _call<void>('deleteDeviceDateFolders', {
    'identifier': identifier,
    'fromDate': from?.toIso8601String().substring(0, 10),
    'toDate': to?.toIso8601String().substring(0, 10),
  });
  Future<void> deleteTelemetryData(String identifier) =>
      _call<void>('deleteTelemetryData', {'identifier': identifier});
  Future<void> setMultiBleConnectionMode(String identifier, bool enable) =>
      _call<void>('setMultiBLEConnectionMode', {
        'identifier': identifier,
        'enable': enable,
      });
  Future<bool> getMultiBleConnectionMode(String identifier) async =>
      (await _call<bool>('getMultiBLEConnectionMode', {
        'identifier': identifier,
      }))!;
  Future<void> setSensorInitiatedSecurityMode(String identifier, bool enable) =>
      _call<void>('setSensorInitiatedSecurityMode', {
        'identifier': identifier,
        'enable': enable,
      });
  Future<bool> getSensorInitiatedSecurityMode(String identifier) async =>
      (await _call<bool>('getSensorInitiatedSecurityMode', {
        'identifier': identifier,
      }))!;
  Future<bool> startSyncNotifications(String identifier) async =>
      (await _call<bool>('sendInitializationAndStartSyncNotifications', {
        'identifier': identifier,
      }))!;
  Future<void> stopSyncNotifications(String identifier) => _call<void>(
    'sendTerminateAndStopSyncNotifications',
    {'identifier': identifier},
  );
  Future<void> setAutomaticOhrMeasurementEnabled(
    String identifier,
    bool enabled,
  ) => _call<void>('setAutomaticOHRMeasurementEnabled', {
    'identifier': identifier,
    'enabled': enabled,
  });

  // ---- low level file system ------------------------------------------------

  Future<Uint8List?> readFile(String identifier, String path) =>
      _call<Uint8List>('readFile', {'identifier': identifier, 'path': path});
  Future<void> writeFile(String identifier, String path, Uint8List data) =>
      _call<void>('writeFile', {
        'identifier': identifier,
        'path': path,
        'data': data,
      });
  Future<void> deleteFileOrDirectory(String identifier, String path) =>
      _call<void>('deleteFileOrDirectory', {
        'identifier': identifier,
        'path': path,
      });
  Future<List<String>> getFileList(
    String identifier,
    String path, {
    bool recurseDeep = false,
  }) => _callStrings('getFileList', {
    'identifier': identifier,
    'path': path,
    'recurseDeep': recurseDeep,
  });
  Future<void> createFolder(String identifier, String path) =>
      _call<void>('createFolder', {'identifier': identifier, 'path': path});

  // ---- logging / telemetry / notifications ----------------------------------

  Future<List<DeviceLog>> exportDeviceLogs(String identifier) async =>
      (await _call<List<Object?>>('exportDeviceLogs', {
        'identifier': identifier,
      }))!.map((e) => DeviceLog.fromMap(e as Map<Object?, Object?>)).toList();
  Future<Map<Object?, Object?>> getLogConfig(String identifier) =>
      _callMap('getLogConfig', {'identifier': identifier});
  Future<void> setLogConfig(String identifier, Map<String, bool?> config) =>
      _call<void>('setLogConfig', {'identifier': identifier, 'config': config});

  Future<Map<Object?, Object?>> getAvailableTelemetryTypes(String identifier) =>
      _callMap('getAvailableTelemetryTypes', {'identifier': identifier});
  Future<Map<Object?, Object?>?> getDeviceTelemetryConfiguration(
    String identifier,
    String telemetryType,
  ) => _call<Map<Object?, Object?>>('getDeviceTelemetryConfiguration', {
    'identifier': identifier,
    'telemetryType': telemetryType,
  });
  Stream<Map<Object?, Object?>> startTelemetry(
    String identifier,
    String telemetryType,
  ) => _openStream('telemetry', {
    'identifier': identifier,
    'telemetryType': telemetryType,
  }, (e) => e as Map<Object?, Object?>);
  Future<bool> stopTelemetry(String identifier, String telemetryType) async =>
      (await _call<bool>('stopTelemetry', {
        'identifier': identifier,
        'telemetryType': telemetryType,
      }))!;

  Stream<Map<Object?, Object?>> d2hNotifications(String identifier) =>
      _openStream('d2hNotifications', {
        'identifier': identifier,
      }, (e) => e as Map<Object?, Object?>);

  // ---- firmware -------------------------------------------------------------

  Stream<FirmwareCheck> checkFirmwareUpdate(String identifier) => _openStream(
    'checkFirmwareUpdate',
    {'identifier': identifier},
    (e) => FirmwareCheck.fromMap(e as Map<Object?, Object?>),
  );

  Stream<FirmwareUpdateStatus> updateFirmware(
    String identifier, {
    String? firmwareUrl,
  }) => _openStream('updateFirmware', {
    'identifier': identifier,
    'firmwareUrl': firmwareUrl,
  }, (e) => FirmwareUpdateStatus.fromMap(e as Map<Object?, Object?>));
}
