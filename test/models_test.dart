import 'package:flutter_test/flutter_test.dart';
import 'package:heild/polar/models.dart';

void main() {
  group('SensorSettingOptions', () {
    test('parses wire map and picks lowest defaults', () {
      final o = SensorSettingOptions.fromMap({
        'SAMPLE_RATE': [52, 26, 104],
        'RANGE': [8, 2, 4, 16],
        'RESOLUTION': [16],
        'CHANNELS': [3],
      });
      expect(o.options[SettingType.sampleRate], [52, 26, 104]);
      final d = o.defaults();
      expect(d.values[SettingType.sampleRate], 52);
      expect(d.values[SettingType.range], 8);
      expect(d.toMap(), {
        'SAMPLE_RATE': 52,
        'RANGE': 8,
        'RESOLUTION': 16,
        'CHANNELS': 3,
      });
    });

    test('copyWith replaces one value', () {
      const s = SensorSetting({
        SettingType.sampleRate: 52,
        SettingType.range: 8,
      });
      final t = s.copyWith(SettingType.sampleRate, 416);
      expect(t.values[SettingType.sampleRate], 416);
      expect(t.values[SettingType.range], 8);
      expect(s.values[SettingType.sampleRate], 52);
    });
  });

  group('PolarDataType', () {
    test('round-trips wire names', () {
      for (final t in PolarDataType.values) {
        expect(PolarDataType.fromWire(t.wire), t);
      }
    });
    test('HR and PPI need no settings', () {
      expect(PolarDataType.hr.needsSettings, isFalse);
      expect(PolarDataType.ppi.needsSettings, isFalse);
      expect(PolarDataType.acc.needsSettings, isTrue);
    });
  });

  group('OfflineRecordingEntry', () {
    test('round-trips through toMap/fromMap', () {
      final e = OfflineRecordingEntry(
        path: '/U/0/20261109/R/093000/ACC.REC',
        size: 12345,
        date: DateTime(2026, 11, 9, 9, 30),
        type: PolarDataType.acc,
      );
      final back = OfflineRecordingEntry.fromMap(e.toMap());
      expect(back.path, e.path);
      expect(back.size, e.size);
      expect(back.date, e.date);
      expect(back.type, e.type);
    });
  });

  group('OfflineRecordingTrigger', () {
    test('maps features with and without settings', () {
      final t = OfflineRecordingTrigger.fromMap({
        'triggerMode': 'TRIGGER_SYSTEM_START',
        'triggerFeatures': {
          'PPI': null,
          'ACC': {
            'SAMPLE_RATE': [52],
            'RANGE': [8],
          },
        },
      });
      expect(t.mode, TriggerMode.systemStart);
      expect(t.features[PolarDataType.ppi], isNull);
      expect(t.features[PolarDataType.acc]!.values[SettingType.range], 8);
      final m = t.toMap();
      expect(m['triggerMode'], 'TRIGGER_SYSTEM_START');
      expect((m['triggerFeatures'] as Map)['ACC'], {
        'SAMPLE_RATE': 52,
        'RANGE': 8,
      });
    });
  });

  group('OfflineFetchEvent', () {
    test('progress and completion', () {
      final p = OfflineFetchEvent.fromMap({
        'kind': 'progress',
        'bytesDownloaded': 10,
        'totalBytes': 100,
        'progressPercent': 10,
      });
      expect(p.isComplete, isFalse);
      expect(p.progressPercent, 10);
      final c = OfflineFetchEvent.fromMap({
        'kind': 'complete',
        'data': {
          'type': 'ACC',
          'startTime': '2026-11-09T09:30:00',
          'settings': {
            'SAMPLE_RATE': [52],
          },
          'sampleCount': 3,
          'first': {'x': 1},
          'last': {'x': 3},
        },
      });
      expect(c.isComplete, isTrue);
      expect(c.data!.sampleCount, 3);
      expect(c.data!.settings!.options[SettingType.sampleRate], [52]);
    });
  });

  test('FirmwareUpdateStatus knows terminal states', () {
    expect(
      FirmwareUpdateStatus.fromMap({'status': 'WritingFwUpdatePackage'})
          .isTerminal,
      isFalse,
    );
    expect(
      FirmwareUpdateStatus.fromMap({'status': 'FwUpdateFailed', 'details': 'x'})
          .isTerminal,
      isTrue,
    );
  });

  test('PhysicalConfig toMap formats dates', () {
    final c = PhysicalConfig(
      gender: 'MALE',
      birthDate: DateTime(1990, 5, 6),
      height: 180,
      weight: 75,
      maxHeartRate: 190,
      vo2Max: 45,
      restingHeartRate: 55,
      trainingBackground: 30,
      deviceTime: '2026-11-09T09:30:00Z',
      typicalDay: 'MOSTLY_MOVING',
      sleepGoalMinutes: 480,
    );
    expect(c.toMap()['birthDate'], '1990-05-06');
    expect(c.toMap()['gender'], 'MALE');
  });
}
