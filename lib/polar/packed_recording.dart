import 'dart:typed_data';

import 'models.dart';

/// A fetched offline recording with its samples as typed arrays.
///
/// Produced by the bridge's `offlineRecordPacked` stream kind. A day of ACC at
/// 26 Hz is ~2.2 M samples; shipping them as one map per sample would need
/// hundreds of MB on the Dart side, typed arrays need a few MB.
///
/// Layout per type (all arrays have [sampleCount] entries unless noted):
/// - ACC: [ts] Polar ns, [xyz] mG interleaved x,y,z (3 × count).
/// - GYRO / MAGNETOMETER: [ts], [xyzF] interleaved floats (3 × count).
/// - HR: [hr] bpm, [flags] bit0 contact, bit1 contact supported.
/// - PPI: [ts] (may be zeros), [ppi] ms, [errorEstimate] ms, [hr] bpm,
///   [flags] bit0 blocker, bit1 skin contact, bit2 skin contact supported.
class PackedRecording {
  PackedRecording({
    required this.type,
    required this.startTimeIso,
    required this.settings,
    required this.sampleCount,
    this.ts,
    this.xyz,
    this.xyzF,
    this.hr,
    this.ppi,
    this.errorEstimate,
    this.flags,
  });

  factory PackedRecording.fromMap(Map<Object?, Object?> m) => PackedRecording(
    type: PolarDataType.fromWire(m['type'] as String),
    startTimeIso: m['startTime'] as String,
    settings: m['settings'] == null
        ? null
        : SensorSettingOptions.fromMap(m['settings'] as Map<Object?, Object?>),
    sampleCount: m['sampleCount'] as int,
    ts: m['ts'] as Int64List?,
    xyz: m['xyz'] as Int32List?,
    xyzF: m['xyzF'] as Float32List?,
    hr: m['hr'] as Int32List?,
    ppi: m['ppi'] as Int32List?,
    errorEstimate: m['errorEstimate'] as Int32List?,
    flags: m['flags'] as Uint8List?,
  );

  final PolarDataType type;

  /// `LocalDateTime.toString()` of the recording start (phone-local time).
  final String startTimeIso;
  final SensorSettingOptions? settings;
  final int sampleCount;
  final Int64List? ts;
  final Int32List? xyz;
  final Float32List? xyzF;
  final Int32List? hr;
  final Int32List? ppi;
  final Int32List? errorEstimate;
  final Uint8List? flags;

  int? get sampleRateHz => settings?.options[SettingType.sampleRate]?.first;
  int? get range => settings?.options[SettingType.range]?.first;
}

/// Progress or completion while fetching a recording through the packed path.
class PackedFetchEvent {
  PackedFetchEvent({this.progressPercent, this.data});

  factory PackedFetchEvent.fromMap(Map<Object?, Object?> m) {
    if (m['kind'] == 'complete') {
      return PackedFetchEvent(
        progressPercent: 100,
        data: PackedRecording.fromMap(m),
      );
    }
    return PackedFetchEvent(progressPercent: m['progressPercent'] as int?);
  }

  final int? progressPercent;
  final PackedRecording? data;

  bool get isComplete => data != null;
}
