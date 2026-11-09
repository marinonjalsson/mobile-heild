/// Plain Dart mirrors of the Polar BLE SDK models, built from the maps the
/// Kotlin bridge sends. Enum values match the Kotlin enum names exactly.
library;

/// Data types a Polar device can stream or record (PolarDeviceDataType).
enum PolarDataType {
  hr('HR'),
  ecg('ECG'),
  acc('ACC'),
  ppg('PPG'),
  ppi('PPI'),
  gyro('GYRO'),
  magnetometer('MAGNETOMETER'),
  pressure('PRESSURE'),
  location('LOCATION'),
  temperature('TEMPERATURE'),
  skinTemperature('SKIN_TEMPERATURE'),
  derivedMeasurement('DERIVED_MEASUREMENT');

  const PolarDataType(this.wire);
  final String wire;

  static PolarDataType fromWire(String s) =>
      values.firstWhere((v) => v.wire == s, orElse: () => derivedMeasurement);

  /// Stream kind understood by the bridge's `openStream`.
  String get streamKind => switch (this) {
    hr => 'hr',
    ecg => 'ecg',
    acc => 'acc',
    ppg => 'ppg',
    ppi => 'ppi',
    gyro => 'gyro',
    magnetometer => 'magnetometer',
    pressure => 'pressure',
    location => 'location',
    temperature => 'temperature',
    skinTemperature => 'skinTemperature',
    derivedMeasurement => 'derived',
  };

  /// HR and PPI take no sensor settings.
  bool get needsSettings => this != hr && this != ppi;

  String get label => switch (this) {
    hr => 'Heart rate',
    ecg => 'ECG',
    acc => 'Accelerometer',
    ppg => 'PPG',
    ppi => 'PP interval',
    gyro => 'Gyroscope',
    magnetometer => 'Magnetometer',
    pressure => 'Pressure',
    location => 'Location',
    temperature => 'Temperature',
    skinTemperature => 'Skin temperature',
    derivedMeasurement => 'Derived',
  };
}

/// Setting dimensions of a stream (PolarSensorSetting.SettingType).
enum SettingType {
  sampleRate('SAMPLE_RATE', 'Sample rate', 'Hz'),
  resolution('RESOLUTION', 'Resolution', 'bit'),
  range('RANGE', 'Range', ''),
  channels('CHANNELS', 'Channels', '');

  const SettingType(this.wire, this.label, this.unit);
  final String wire;
  final String label;
  final String unit;

  static SettingType? fromWire(String s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Available options per setting type, as returned by requestStreamSettings.
class SensorSettingOptions {
  SensorSettingOptions(this.options);

  factory SensorSettingOptions.fromMap(Map<Object?, Object?> m) {
    final out = <SettingType, List<int>>{};
    m.forEach((k, v) {
      final t = SettingType.fromWire(k as String);
      if (t != null) out[t] = (v as List).cast<int>();
    });
    return SensorSettingOptions(out);
  }

  final Map<SettingType, List<int>> options;

  bool get isEmpty => options.isEmpty;

  /// Default selection: the SDK's `maxSettings()` picks the maximum of each.
  /// We prefer the first (lowest) value, which matches the device defaults
  /// (52 Hz, 8 G) better for the Verity Sense.
  SensorSetting defaults() => SensorSetting({
    for (final e in options.entries)
      if (e.value.isNotEmpty) e.key: e.value.first,
  });
}

/// One chosen value per setting type, sent when starting a stream.
class SensorSetting {
  const SensorSetting(this.values);
  final Map<SettingType, int> values;

  Map<String, int> toMap() => {
    for (final e in values.entries) e.key.wire: e.value,
  };

  SensorSetting copyWith(SettingType type, int value) =>
      SensorSetting({...values, type: value});

  @override
  String toString() => values.entries
      .map((e) => '${e.key.label} ${e.value}${e.key.unit}')
      .join(', ');
}

class PolarDeviceInfo {
  PolarDeviceInfo({
    required this.deviceId,
    required this.address,
    required this.rssi,
    required this.name,
    required this.isConnectable,
    required this.hasHeartRateService,
    required this.hasFileSystemService,
  });

  factory PolarDeviceInfo.fromMap(Map<Object?, Object?> m) => PolarDeviceInfo(
    deviceId: m['deviceId'] as String,
    address: m['address'] as String,
    rssi: m['rssi'] as int,
    name: m['name'] as String,
    isConnectable: m['isConnectable'] as bool,
    hasHeartRateService: m['hasHeartRateService'] as bool? ?? false,
    hasFileSystemService: m['hasFileSystemService'] as bool? ?? false,
  );

  final String deviceId;
  final String address;
  final int rssi;
  final String name;
  final bool isConnectable;
  final bool hasHeartRateService;
  final bool hasFileSystemService;
}

class DisconnectInfo {
  DisconnectInfo({
    required this.reason,
    required this.recoveryAction,
    this.gattStatus,
    this.deviceCommand,
  });

  factory DisconnectInfo.fromMap(Map<Object?, Object?> m) => DisconnectInfo(
    reason: m['reason'] as String,
    recoveryAction: m['recoveryAction'] as String,
    gattStatus: m['gattStatus'] as int?,
    deviceCommand: m['deviceCommand'] as String?,
  );

  final String reason;
  final String recoveryAction;
  final int? gattStatus;
  final String? deviceCommand;

  @override
  String toString() =>
      '$reason${deviceCommand != null ? ' ($deviceCommand)' : ''}, recovery: $recoveryAction';
}

class HrSample {
  HrSample({
    required this.hr,
    required this.correctedHr,
    required this.ppgQuality,
    required this.rrsMs,
    required this.rrAvailable,
    required this.contactStatus,
    required this.contactStatusSupported,
  });

  factory HrSample.fromMap(Map<Object?, Object?> m) => HrSample(
    hr: m['hr'] as int,
    correctedHr: m['correctedHr'] as int? ?? 0,
    ppgQuality: m['ppgQuality'] as int? ?? 0,
    rrsMs: (m['rrsMs'] as List?)?.cast<int>() ?? const [],
    rrAvailable: m['rrAvailable'] as bool? ?? false,
    contactStatus: m['contactStatus'] as bool? ?? false,
    contactStatusSupported: m['contactStatusSupported'] as bool? ?? false,
  );

  final int hr;
  final int correctedHr;
  final int ppgQuality;
  final List<int> rrsMs;
  final bool rrAvailable;
  final bool contactStatus;
  final bool contactStatusSupported;
}

class PpiSample {
  PpiSample({
    required this.ppi,
    required this.errorEstimate,
    required this.hr,
    required this.blockerBit,
    required this.skinContactStatus,
    required this.skinContactSupported,
    required this.timeStamp,
  });

  factory PpiSample.fromMap(Map<Object?, Object?> m) => PpiSample(
    ppi: m['ppi'] as int,
    errorEstimate: m['errorEstimate'] as int,
    hr: m['hr'] as int,
    blockerBit: m['blockerBit'] as bool,
    skinContactStatus: m['skinContactStatus'] as bool,
    skinContactSupported: m['skinContactSupported'] as bool,
    timeStamp: m['timeStamp'] as int,
  );

  final int ppi;
  final int errorEstimate;
  final int hr;
  final bool blockerBit;
  final bool skinContactStatus;
  final bool skinContactSupported;
  final int timeStamp;
}

/// A three-axis sample (ACC in mG as ints, GYRO deg/s and MAG gauss as doubles).
class XyzSample {
  XyzSample({
    required this.timeStamp,
    required this.x,
    required this.y,
    required this.z,
  });

  factory XyzSample.fromMap(Map<Object?, Object?> m) => XyzSample(
    timeStamp: m['timeStamp'] as int,
    x: (m['x'] as num).toDouble(),
    y: (m['y'] as num).toDouble(),
    z: (m['z'] as num).toDouble(),
  );

  final int timeStamp;
  final double x;
  final double y;
  final double z;
}

class PpgSample {
  PpgSample({
    required this.timeStamp,
    required this.channelSamples,
    required this.statusBits,
  });

  factory PpgSample.fromMap(Map<Object?, Object?> m) => PpgSample(
    timeStamp: m['timeStamp'] as int,
    channelSamples: (m['channelSamples'] as List).cast<int>(),
    statusBits: (m['statusBits'] as List?)?.cast<int>() ?? const [],
  );

  final int timeStamp;
  final List<int> channelSamples;
  final List<int> statusBits;
}

/// One batch emitted by a stream: `{type, samples: [...]}` plus type-specific fields.
class StreamBatch {
  StreamBatch(this.type, this.raw);

  factory StreamBatch.fromMap(Map<Object?, Object?> m) =>
      StreamBatch(PolarDataType.fromWire(m['type'] as String), m);

  final PolarDataType type;
  final Map<Object?, Object?> raw;

  List<Map<Object?, Object?>> get samples =>
      (raw['samples'] as List).cast<Map<Object?, Object?>>();

  String? get ppgDataType => raw['ppgDataType'] as String?;
}

class OfflineRecordingEntry {
  OfflineRecordingEntry({
    required this.path,
    required this.size,
    required this.date,
    required this.type,
  });

  factory OfflineRecordingEntry.fromMap(Map<Object?, Object?> m) =>
      OfflineRecordingEntry(
        path: m['path'] as String,
        size: m['size'] as int,
        date: DateTime.parse(m['date'] as String),
        type: PolarDataType.fromWire(m['type'] as String),
      );

  final String path;
  final int size;
  final DateTime date;
  final PolarDataType type;

  Map<String, Object?> toMap() => {
    'path': path,
    'size': size,
    'date': date.toIso8601String(),
    'type': type.wire,
  };
}

/// Summary of a fetched recording (the bridge does not ship every sample).
class OfflineRecordingSummary {
  OfflineRecordingSummary({
    required this.type,
    required this.startTime,
    required this.settings,
    required this.sampleCount,
    required this.first,
    required this.last,
  });

  factory OfflineRecordingSummary.fromMap(Map<Object?, Object?> m) =>
      OfflineRecordingSummary(
        type: m['type'] as String,
        startTime: DateTime.parse(m['startTime'] as String),
        settings: m['settings'] == null
            ? null
            : SensorSettingOptions.fromMap(
                m['settings'] as Map<Object?, Object?>,
              ),
        sampleCount: m['sampleCount'] as int,
        first: m['first'] as Map<Object?, Object?>?,
        last: m['last'] as Map<Object?, Object?>?,
      );

  final String type;
  final DateTime startTime;
  final SensorSettingOptions? settings;
  final int sampleCount;
  final Map<Object?, Object?>? first;
  final Map<Object?, Object?>? last;
}

/// Progress or completion event while fetching a recording.
class OfflineFetchEvent {
  OfflineFetchEvent({
    this.bytesDownloaded,
    this.totalBytes,
    this.progressPercent,
    this.data,
  });

  factory OfflineFetchEvent.fromMap(Map<Object?, Object?> m) {
    if (m['kind'] == 'complete') {
      return OfflineFetchEvent(
        data: OfflineRecordingSummary.fromMap(
          m['data'] as Map<Object?, Object?>,
        ),
      );
    }
    return OfflineFetchEvent(
      bytesDownloaded: m['bytesDownloaded'] as int,
      totalBytes: m['totalBytes'] as int,
      progressPercent: m['progressPercent'] as int,
    );
  }

  final int? bytesDownloaded;
  final int? totalBytes;
  final int? progressPercent;
  final OfflineRecordingSummary? data;

  bool get isComplete => data != null;
}

enum TriggerMode {
  disabled('TRIGGER_DISABLED', 'Disabled'),
  systemStart('TRIGGER_SYSTEM_START', 'On device start'),
  exerciseStart('TRIGGER_EXERCISE_START', 'On exercise start');

  const TriggerMode(this.wire, this.label);
  final String wire;
  final String label;

  static TriggerMode fromWire(String s) =>
      values.firstWhere((v) => v.wire == s, orElse: () => disabled);
}

class OfflineRecordingTrigger {
  OfflineRecordingTrigger({required this.mode, required this.features});

  factory OfflineRecordingTrigger.fromMap(Map<Object?, Object?> m) {
    final features = <PolarDataType, SensorSetting?>{};
    (m['triggerFeatures'] as Map<Object?, Object?>? ?? {}).forEach((k, v) {
      final type = PolarDataType.fromWire(k as String);
      features[type] = v == null
          ? null
          : SensorSettingOptions.fromMap(v as Map<Object?, Object?>).defaults();
    });
    return OfflineRecordingTrigger(
      mode: TriggerMode.fromWire(m['triggerMode'] as String),
      features: features,
    );
  }

  final TriggerMode mode;
  final Map<PolarDataType, SensorSetting?> features;

  Map<String, Object?> toMap() => {
    'triggerMode': mode.wire,
    'triggerFeatures': {
      for (final e in features.entries) e.key.wire: e.value?.toMap(),
    },
  };
}

class DiskSpace {
  DiskSpace({required this.totalSpace, required this.freeSpace});

  factory DiskSpace.fromMap(Map<Object?, Object?> m) => DiskSpace(
    totalSpace: m['totalSpace'] as int,
    freeSpace: m['freeSpace'] as int,
  );

  final int totalSpace;
  final int freeSpace;
}

class LedConfig {
  const LedConfig({
    this.sdkModeLedEnabled = true,
    this.ppiModeLedEnabled = true,
  });
  final bool sdkModeLedEnabled;
  final bool ppiModeLedEnabled;

  Map<String, Object?> toMap() => {
    'sdkModeLedEnabled': sdkModeLedEnabled,
    'ppiModeLedEnabled': ppiModeLedEnabled,
  };
}

/// First-time-use / physical configuration (PolarFirstTimeUseConfig).
class PhysicalConfig {
  PhysicalConfig({
    required this.gender,
    required this.birthDate,
    required this.height,
    required this.weight,
    required this.maxHeartRate,
    required this.vo2Max,
    required this.restingHeartRate,
    required this.trainingBackground,
    required this.deviceTime,
    required this.typicalDay,
    required this.sleepGoalMinutes,
  });

  factory PhysicalConfig.fromMap(Map<Object?, Object?> m) => PhysicalConfig(
    gender: m['gender'] as String,
    birthDate: DateTime.parse(m['birthDate'] as String),
    height: (m['height'] as num).toDouble(),
    weight: (m['weight'] as num).toDouble(),
    maxHeartRate: m['maxHeartRate'] as int,
    vo2Max: m['vo2Max'] as int,
    restingHeartRate: m['restingHeartRate'] as int,
    trainingBackground: m['trainingBackground'] as int,
    deviceTime: m['deviceTime'] as String,
    typicalDay: m['typicalDay'] as String,
    sleepGoalMinutes: m['sleepGoalMinutes'] as int,
  );

  static const genders = ['MALE', 'FEMALE'];
  static const typicalDays = [
    'MOSTLY_SITTING',
    'MOSTLY_STANDING',
    'MOSTLY_MOVING',
  ];
  static const trainingBackgrounds = [10, 20, 30, 40, 50, 60];

  final String gender;
  final DateTime birthDate;
  final double height;
  final double weight;
  final int maxHeartRate;
  final int vo2Max;
  final int restingHeartRate;
  final int trainingBackground;
  final String deviceTime;
  final String typicalDay;
  final int sleepGoalMinutes;

  Map<String, Object?> toMap() => {
    'gender': gender,
    'birthDate': birthDate.toIso8601String().substring(0, 10),
    'height': height,
    'weight': weight,
    'maxHeartRate': maxHeartRate,
    'vo2Max': vo2Max,
    'restingHeartRate': restingHeartRate,
    'trainingBackground': trainingBackground,
    'deviceTime': deviceTime,
    'typicalDay': typicalDay,
    'sleepGoalMinutes': sleepGoalMinutes,
  };
}

class UserDeviceSettings {
  UserDeviceSettings.fromMap(Map<Object?, Object?> m)
    : deviceLocation = m['deviceLocation'] as int?,
      deviceLocationName = m['deviceLocationName'] as String?,
      usbConnectionMode = m['usbConnectionMode'] as bool?,
      automaticTrainingDetectionMode =
          m['automaticTrainingDetectionMode'] as bool?,
      automaticTrainingDetectionSensitivity =
          m['automaticTrainingDetectionSensitivity'] as int?,
      minimumTrainingDurationSeconds =
          m['minimumTrainingDurationSeconds'] as int?,
      telemetryEnabled = m['telemetryEnabled'] as bool?,
      autosFilesEnabled = m['autosFilesEnabled'] as bool?;

  final int? deviceLocation;
  final String? deviceLocationName;
  final bool? usbConnectionMode;
  final bool? automaticTrainingDetectionMode;
  final int? automaticTrainingDetectionSensitivity;
  final int? minimumTrainingDurationSeconds;
  final bool? telemetryEnabled;
  final bool? autosFilesEnabled;

  /// PolarUserDeviceSettings.DeviceLocation values.
  static const locations = <int, String>{
    0: 'UNDEFINED',
    1: 'OTHER',
    2: 'WRIST_LEFT',
    3: 'WRIST_RIGHT',
    4: 'NECKLACE',
    5: 'CHEST',
    6: 'UPPER_BACK',
    7: 'FOOT_LEFT',
    8: 'FOOT_RIGHT',
    9: 'LOWER_ARM_LEFT',
    10: 'LOWER_ARM_RIGHT',
    11: 'UPPER_ARM_LEFT',
    12: 'UPPER_ARM_RIGHT',
    13: 'BIKE_MOUNT',
  };
}

/// Stored data types that can be deleted (PolarStoredDataType).
const storedDataTypes = [
  'ACTIVITY',
  'AUTO_SAMPLE',
  'DAILY_SUMMARY',
  'NIGHTLY_RECOVERY',
  'SDLOGS',
  'SLEEP',
  'SLEEP_SCORE',
  'SKIN_CONTACT_CHANGES',
  'SKIN_TEMP',
  'SPO2_TEST',
];

class FirmwareCheck {
  FirmwareCheck.fromMap(Map<Object?, Object?> m)
    : status = m['status'] as String,
      version = m['version'] as String?,
      mandatoryUpdate = m['mandatoryUpdate'] as bool?,
      details = m['details'] as String?;

  final String status;
  final String? version;
  final bool? mandatoryUpdate;
  final String? details;
}

class FirmwareUpdateStatus {
  FirmwareUpdateStatus.fromMap(Map<Object?, Object?> m)
    : status = m['status'] as String,
      details = m['details'] as String? ?? '';

  final String status;
  final String details;

  bool get isTerminal =>
      status == 'FwUpdateCompletedSuccessfully' ||
      status == 'FwUpdateNotAvailable' ||
      status == 'FwUpdateFailed';
}

class DeviceLog {
  DeviceLog.fromMap(Map<Object?, Object?> m)
    : path = m['path'] as String,
      size = m['size'] as int,
      data = m['data'] as List<int>;

  final String path;
  final int size;
  final List<int> data;
}

class HrBroadcast {
  HrBroadcast.fromMap(Map<Object?, Object?> m)
    : device = PolarDeviceInfo.fromMap(m['device'] as Map<Object?, Object?>),
      hr = m['hr'] as int,
      batteryStatus = m['batteryStatus'] as bool;

  final PolarDeviceInfo device;
  final int hr;
  final bool batteryStatus;
}

/// Events from the SDK callback provider (`heild/polar/events`).
class PolarEvent {
  PolarEvent(this.type, this.raw);

  factory PolarEvent.fromMap(Map<Object?, Object?> m) =>
      PolarEvent(m['type'] as String, m);

  final String type;
  final Map<Object?, Object?> raw;

  String? get identifier => raw['identifier'] as String?;
  PolarDeviceInfo? get device => raw['device'] == null
      ? null
      : PolarDeviceInfo.fromMap(raw['device'] as Map<Object?, Object?>);
}
