import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../widgets/common.dart';

/// Device management: info, SDK mode, time, disk, LED, physical config,
/// user device settings, data deletion, feature configuration and power operations.
class DeviceTab extends StatefulWidget {
  const DeviceTab({super.key});

  @override
  State<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<DeviceTab>
    with AutomaticKeepAliveClientMixin {
  bool? _sdkMode;
  String? _deviceTime;
  DiskSpace? _disk;
  int? _rssi;
  bool _ledSdk = true;
  bool _ledPpi = true;
  bool? _ftuDone;
  PhysicalConfig? _physical;
  UserDeviceSettings? _userSettings;
  bool? _multiBle;
  bool? _sensorSecurity;
  String _deleteType = storedDataTypes.first;
  DateTime? _deleteUntil;
  DateTime? _folderFrom;
  DateTime? _folderTo;

  @override
  bool get wantKeepAlive => true;

  DeviceController get dc => deviceController;
  String get id => dc.deviceId!;

  Future<void> _do(Future<void> Function() f, {String? success}) =>
      runAction(context, f, success: success);

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
    context: context,
    initialDate: initial ?? DateTime.now(),
    firstDate: DateTime(2015),
    lastDate: DateTime(2100),
  );

  Future<void> _powerOp(
    String title,
    String body,
    String word,
    Future<void> Function() op,
  ) async {
    if (!await confirmTyped(context, title: title, body: body, word: word))
      return;
    if (!mounted) return;
    await _do(op, success: '$title sent');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: dc,
      builder: (context, _) {
        final on = dc.isConnected;
        final ctrl =
            on && dc.featuresReady.contains('FEATURE_POLAR_DEVICE_CONTROL');
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Section(
              title: 'Information',
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: !on
                    ? null
                    : () => _do(() async {
                        _rssi = await dc.bridge.getRssi(id);
                        setState(() {});
                      }),
              ),
              children: [
                KeyValueList({
                  'Name': dc.device?.name,
                  'Device ID': dc.deviceId,
                  'Address': dc.device?.address,
                  'Battery': dc.batteryLevel == null
                      ? null
                      : '${dc.batteryLevel}%',
                  'Charge state': dc.chargeState,
                  'RSSI': _rssi == null ? null : '$_rssi dBm',
                  ...dc.disInfo.map((k, v) => MapEntry(_disLabel(k), v)),
                  'Features ready': dc.featuresReady.map(_short).join(', '),
                  'Unavailable': dc.featuresUnavailable.map(_short).join(', '),
                  if (dc.lastDisconnect != null)
                    'Last disconnect': dc.lastDisconnect.toString(),
                }),
              ],
            ),
            Section(
              title: 'SDK mode',
              trailing: Switch(
                value: _sdkMode ?? false,
                onChanged: !on
                    ? null
                    : (v) => _do(() async {
                        await dc.stopAllStreams();
                        if (v) {
                          await dc.bridge.enableSdkMode(id);
                        } else {
                          await dc.bridge.disableSdkMode(id);
                        }
                        setState(() => _sdkMode = v);
                      }, success: v ? 'SDK mode enabled' : 'SDK mode disabled'),
              ),
              children: [
                Text(
                  _sdkMode == null
                      ? 'State unknown. Tap Read.'
                      : (_sdkMode! ? 'Enabled' : 'Disabled'),
                ),
                const Text(
                  'SDK mode unlocks higher rates and ranges for ACC/Gyro/Mag/PPG. HR and PPI are unavailable while it is on.',
                  style: TextStyle(fontSize: 12),
                ),
                ButtonRow([
                  TextButton(
                    onPressed: !on
                        ? null
                        : () => _do(() async {
                            final v = await dc.bridge.isSdkModeEnabled(id);
                            setState(() => _sdkMode = v);
                          }),
                    child: const Text('Read'),
                  ),
                ]),
              ],
            ),
            Section(
              title: 'Time',
              children: [
                Text(_deviceTime ?? 'Device time not read yet.'),
                ButtonRow([
                  TextButton(
                    onPressed: !on
                        ? null
                        : () => _do(() async {
                            final t = await dc.bridge.getLocalTimeRaw(id);
                            setState(() => _deviceTime = t);
                          }),
                    child: const Text('Read'),
                  ),
                  FilledButton.tonal(
                    onPressed: !on
                        ? null
                        : () => _do(
                            () => dc.bridge.setLocalTime(id, DateTime.now()),
                            success: 'Time set to phone time',
                          ),
                    child: const Text('Set to phone time'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _do(
                            () => dc.bridge.setDaylightSavingTime(id),
                            success: 'DST set',
                          ),
                    child: const Text('Set next DST'),
                  ),
                ]),
              ],
            ),
            Section(
              title: 'Storage',
              trailing: TextButton(
                onPressed: !ctrl
                    ? null
                    : () => _do(() async {
                        final d = await dc.bridge.getDiskSpace(id);
                        setState(() => _disk = d);
                      }),
                child: const Text('Read'),
              ),
              children: [
                if (_disk == null)
                  const Text('Disk space not read yet.')
                else ...[
                  LinearProgressIndicator(
                    value: 1 - _disk!.freeSpace / _disk!.totalSpace,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(_disk!.freeSpace)} free of ${formatBytes(_disk!.totalSpace)}',
                  ),
                ],
              ],
            ),
            Section(
              title: 'LEDs (firmware 2.2.1+)',
              trailing: FilledButton.tonal(
                onPressed: !on
                    ? null
                    : () => _do(
                        () => dc.bridge.setLedConfig(
                          id,
                          LedConfig(
                            sdkModeLedEnabled: _ledSdk,
                            ppiModeLedEnabled: _ledPpi,
                          ),
                        ),
                        success: 'LED config written',
                      ),
                child: const Text('Apply'),
              ),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Blink in SDK mode'),
                  value: _ledSdk,
                  onChanged: (v) => setState(() => _ledSdk = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Blink in PPI mode'),
                  value: _ledPpi,
                  onChanged: (v) => setState(() => _ledPpi = v),
                ),
              ],
            ),
            Section(
              title: 'Physical data (first-time use)',
              trailing: ButtonRow([
                TextButton(
                  onPressed: !ctrl
                      ? null
                      : () => _do(() async {
                          final done = await dc.bridge.isFtuDone(id);
                          final p = await dc.bridge
                              .getUserPhysicalConfiguration(id);
                          setState(() {
                            _ftuDone = done;
                            _physical = p;
                          });
                        }),
                  child: const Text('Read'),
                ),
                FilledButton.tonal(
                  onPressed: !ctrl ? null : () => _editPhysical(),
                  child: const Text('Edit'),
                ),
              ]),
              children: [
                if (_ftuDone != null)
                  Text('First-time use done: ${_ftuDone! ? 'yes' : 'no'}'),
                if (_physical != null)
                  KeyValueList({
                    'Gender': _physical!.gender,
                    'Birth date': _physical!.birthDate
                        .toIso8601String()
                        .substring(0, 10),
                    'Height': '${_physical!.height} cm',
                    'Weight': '${_physical!.weight} kg',
                    'Max HR': '${_physical!.maxHeartRate} bpm',
                    'Resting HR': '${_physical!.restingHeartRate} bpm',
                    'VO2max': '${_physical!.vo2Max}',
                    'Training background': '${_physical!.trainingBackground}',
                    'Typical day': _physical!.typicalDay,
                    'Sleep goal': '${_physical!.sleepGoalMinutes} min',
                    'Device time': _physical!.deviceTime,
                  })
                else
                  const Text('Not read.'),
              ],
            ),
            Section(
              title: 'User device settings',
              trailing: TextButton(
                onPressed: !ctrl
                    ? null
                    : () => _do(() async {
                        final s = await dc.bridge.getUserDeviceSettings(id);
                        setState(() => _userSettings = s);
                      }),
                child: const Text('Read'),
              ),
              children: [
                if (_userSettings != null)
                  KeyValueList({
                    'Device location':
                        '${_userSettings!.deviceLocationName ?? '—'} (${_userSettings!.deviceLocation})',
                    'USB connection mode': _userSettings!.usbConnectionMode
                        ?.toString(),
                    'Auto training detection': _userSettings!
                        .automaticTrainingDetectionMode
                        ?.toString(),
                    'Detection sensitivity': _userSettings!
                        .automaticTrainingDetectionSensitivity
                        ?.toString(),
                    'Min training duration':
                        _userSettings!.minimumTrainingDurationSeconds == null
                        ? null
                        : '${_userSettings!.minimumTrainingDurationSeconds} s',
                    'Telemetry enabled': _userSettings!.telemetryEnabled
                        ?.toString(),
                    '24/7 OHR (AUTOS)': _userSettings!.autosFilesEnabled
                        ?.toString(),
                  })
                else
                  const Text('Not read.'),
                ButtonRow([
                  TextButton(
                    onPressed: !ctrl ? null : _setLocation,
                    child: const Text('Location…'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _setBool(
                            'USB connection mode',
                            dc.bridge.setUsbConnectionMode,
                          ),
                    child: const Text('USB mode…'),
                  ),
                  TextButton(
                    onPressed: !ctrl ? null : _setTrainingDetection,
                    child: const Text('Auto training…'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _setBool(
                            'Telemetry',
                            dc.bridge.setTelemetryEnabled,
                          ),
                    child: const Text('Telemetry…'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _setBool(
                            '24/7 optical HR (AUTOS files)',
                            dc.bridge.setAutomaticOhrMeasurementEnabled,
                          ),
                    child: const Text('24/7 OHR…'),
                  ),
                ]),
              ],
            ),
            Section(
              title: 'Feature configuration service',
              trailing: TextButton(
                onPressed: !on
                    ? null
                    : () => _do(() async {
                        final m = await dc.bridge.getMultiBleConnectionMode(id);
                        final s = await dc.bridge
                            .getSensorInitiatedSecurityMode(id);
                        setState(() {
                          _multiBle = m;
                          _sensorSecurity = s;
                        });
                      }),
                child: const Text('Read'),
              ),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Multi BLE connection mode'),
                  subtitle: Text(_multiBle == null ? 'unknown' : '$_multiBle'),
                  value: _multiBle ?? false,
                  onChanged: !on
                      ? null
                      : (v) => _do(() async {
                          await dc.bridge.setMultiBleConnectionMode(id, v);
                          setState(() => _multiBle = v);
                        }, success: 'Multi BLE set'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sensor initiated security mode'),
                  subtitle: Text(
                    _sensorSecurity == null ? 'unknown' : '$_sensorSecurity',
                  ),
                  value: _sensorSecurity ?? false,
                  onChanged: !on
                      ? null
                      : (v) => _do(() async {
                          await dc.bridge.setSensorInitiatedSecurityMode(id, v);
                          setState(() => _sensorSecurity = v);
                        }, success: 'Security mode set'),
                ),
                ButtonRow([
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _do(() async {
                            final ok = await dc.bridge.startSyncNotifications(
                              id,
                            );
                            if (!ok)
                              throw Exception(
                                'device refused start-sync notification',
                              );
                          }, success: 'Sync mode started (fast transfer)'),
                    child: const Text('Start sync'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () => _do(
                            () => dc.bridge.stopSyncNotifications(id),
                            success: 'Sync mode stopped',
                          ),
                    child: const Text('Stop sync'),
                  ),
                ]),
              ],
            ),
            Section(
              title: 'Delete data on device',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _deleteType,
                        decoration: const InputDecoration(
                          labelText: 'Stored data type',
                        ),
                        items: [
                          for (final t in storedDataTypes)
                            DropdownMenuItem(value: t, child: Text(t)),
                        ],
                        onChanged: (v) =>
                            setState(() => _deleteType = v ?? _deleteType),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final d = await _pickDate(_deleteUntil);
                        if (d != null) setState(() => _deleteUntil = d);
                      },
                      child: Text(
                        _deleteUntil == null
                            ? 'until…'
                            : _deleteUntil!.toIso8601String().substring(0, 10),
                      ),
                    ),
                  ],
                ),
                ButtonRow([
                  FilledButton.tonal(
                    onPressed: !ctrl
                        ? null
                        : () async {
                            if (!await confirmSimple(
                              context,
                              title: 'Delete $_deleteType?',
                              body:
                                  'Deletes $_deleteType data${_deleteUntil == null ? '' : ' until $_deleteUntil'} from the device.',
                            )) {
                              return;
                            }
                            await _do(
                              () => dc.bridge.deleteStoredDeviceData(
                                id,
                                _deleteType,
                                until: _deleteUntil,
                              ),
                              success: 'Deleted',
                            );
                          },
                    child: const Text('Delete stored data'),
                  ),
                ]),
                const Divider(),
                Row(
                  children: [
                    const Expanded(child: Text('Day folders')),
                    TextButton(
                      onPressed: () async {
                        final d = await _pickDate(_folderFrom);
                        if (d != null) setState(() => _folderFrom = d);
                      },
                      child: Text(
                        _folderFrom == null
                            ? 'from…'
                            : _folderFrom!.toIso8601String().substring(0, 10),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final d = await _pickDate(_folderTo);
                        if (d != null) setState(() => _folderTo = d);
                      },
                      child: Text(
                        _folderTo == null
                            ? 'to…'
                            : _folderTo!.toIso8601String().substring(0, 10),
                      ),
                    ),
                  ],
                ),
                ButtonRow([
                  FilledButton.tonal(
                    onPressed: !ctrl || _folderFrom == null || _folderTo == null
                        ? null
                        : () async {
                            if (!await confirmTyped(
                              context,
                              title: 'Delete day folders',
                              body:
                                  'Deletes every day folder from $_folderFrom to $_folderTo with all contents.',
                              word: 'DELETE',
                            )) {
                              return;
                            }
                            await _do(
                              () => dc.bridge.deleteDeviceDateFolders(
                                id,
                                from: _folderFrom,
                                to: _folderTo,
                              ),
                              success: 'Folders deleted',
                            );
                          },
                    child: const Text('Delete day folders'),
                  ),
                  TextButton(
                    onPressed: !ctrl
                        ? null
                        : () async {
                            if (!await confirmSimple(
                              context,
                              title: 'Delete telemetry data?',
                              body: 'Removes all telemetry files.',
                            )) {
                              return;
                            }
                            await _do(
                              () => dc.bridge.deleteTelemetryData(id),
                              success: 'Telemetry data deleted',
                            );
                          },
                    child: const Text('Delete telemetry data'),
                  ),
                ]),
              ],
            ),
            Section(
              title: 'Power',
              children: [
                const Text(
                  'All of these disconnect the device. Factory reset and warehouse sleep erase data.',
                  style: TextStyle(fontSize: 12),
                ),
                ButtonRow([
                  FilledButton.tonal(
                    onPressed: !ctrl
                        ? null
                        : () => _powerOp(
                            'Restart',
                            'Restarts the sensor.',
                            'RESTART',
                            () => dc.bridge.doRestart(id),
                          ),
                    child: const Text('Restart'),
                  ),
                  FilledButton.tonal(
                    onPressed: !ctrl
                        ? null
                        : () => _powerOp(
                            'Turn off',
                            'Puts the sensor to sleep. Press its button to wake it.',
                            'OFF',
                            () => dc.bridge.turnDeviceOff(id),
                          ),
                    child: const Text('Turn off'),
                  ),
                  FilledButton.tonal(
                    onPressed: !ctrl
                        ? null
                        : () => _powerOp(
                            'Hibernate',
                            'Low-power state that keeps the device time. Battery lasts for weeks to months.',
                            'HIBERNATE',
                            () => dc.bridge.setHibernateMode(id),
                          ),
                    child: const Text('Hibernate'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: !ctrl
                        ? null
                        : () => _powerOp(
                            'Factory reset',
                            'Erases all data and settings on the sensor, including offline recordings.',
                            'RESET',
                            () => dc.bridge.doFactoryReset(id),
                          ),
                    child: const Text('Factory reset'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: !ctrl
                        ? null
                        : () => _powerOp(
                            'Warehouse sleep',
                            'Factory resets the sensor and puts it in storage sleep.',
                            'WAREHOUSE',
                            () => dc.bridge.setWarehouseSleep(id),
                          ),
                    child: const Text('Warehouse sleep'),
                  ),
                ]),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _short(String feature) =>
      feature.replaceFirst('FEATURE_', '').replaceFirst('POLAR_', '');

  static String _disLabel(String key) {
    const names = {
      '00002a26': 'Firmware',
      '00002a27': 'Hardware',
      '00002a28': 'Software',
      '00002a24': 'Model',
      '00002a25': 'Serial',
      '00002a29': 'Manufacturer',
      '00002a23': 'System ID',
    };
    final k = key.toLowerCase();
    for (final e in names.entries) {
      if (k.startsWith(e.key)) return e.value;
    }
    return key;
  }

  Future<void> _setBool(
    String title,
    Future<void> Function(String id, bool v) setter,
  ) async {
    final v = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enable'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await _do(
      () => setter(id, v),
      success: '$title ${v ? 'enabled' : 'disabled'}',
    );
  }

  Future<void> _setLocation() async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Device location'),
        children: [
          for (final e in UserDeviceSettings.locations.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Text(e.value),
            ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await _do(
      () => dc.bridge.setUserDeviceLocation(id, v),
      success: 'Location set',
    );
  }

  Future<void> _setTrainingDetection() async {
    var mode = _userSettings?.automaticTrainingDetectionMode ?? false;
    final sens = TextEditingController(
      text: '${_userSettings?.automaticTrainingDetectionSensitivity ?? 1}',
    );
    final dur = TextEditingController(
      text: '${_userSettings?.minimumTrainingDurationSeconds ?? 600}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Automatic training detection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Enabled'),
                value: mode,
                onChanged: (v) => setS(() => mode = v),
              ),
              TextField(
                controller: sens,
                decoration: const InputDecoration(labelText: 'Sensitivity'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: dur,
                decoration: const InputDecoration(
                  labelText: 'Minimum duration (s)',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _do(
      () => dc.bridge.setAutomaticTrainingDetectionSettings(
        id,
        mode: mode,
        sensitivity: int.tryParse(sens.text) ?? 1,
        minimumDuration: int.tryParse(dur.text) ?? 600,
      ),
      success: 'Training detection set',
    );
    sens.dispose();
    dur.dispose();
  }

  Future<void> _editPhysical() async {
    final p = _physical;
    var gender = p?.gender ?? 'MALE';
    var birth = p?.birthDate ?? DateTime(1990, 1, 1);
    var typical = p?.typicalDay ?? 'MOSTLY_SITTING';
    var background = p?.trainingBackground ?? 10;
    final height = TextEditingController(text: '${p?.height ?? 175}');
    final weight = TextEditingController(text: '${p?.weight ?? 70}');
    final maxHr = TextEditingController(text: '${p?.maxHeartRate ?? 190}');
    final restHr = TextEditingController(text: '${p?.restingHeartRate ?? 60}');
    final vo2 = TextEditingController(text: '${p?.vo2Max ?? 40}');
    final sleep = TextEditingController(text: '${p?.sleepGoalMinutes ?? 480}');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Physical data'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: gender,
                  decoration: const InputDecoration(labelText: 'Gender'),
                  items: [
                    for (final g in PhysicalConfig.genders)
                      DropdownMenuItem(value: g, child: Text(g)),
                  ],
                  onChanged: (v) => setS(() => gender = v ?? gender),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Birth date'),
                  subtitle: Text(birth.toIso8601String().substring(0, 10)),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: birth,
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                    );
                    if (d != null) setS(() => birth = d);
                  },
                ),
                TextField(
                  controller: height,
                  decoration: const InputDecoration(
                    labelText: 'Height cm (90–240)',
                  ),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: weight,
                  decoration: const InputDecoration(
                    labelText: 'Weight kg (15–300)',
                  ),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: maxHr,
                  decoration: const InputDecoration(
                    labelText: 'Max HR (100–240)',
                  ),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: restHr,
                  decoration: const InputDecoration(
                    labelText: 'Resting HR (20–120)',
                  ),
                  keyboardType: TextInputType.number,
                ),
                TextField(
                  controller: vo2,
                  decoration: const InputDecoration(
                    labelText: 'VO2max (10–95)',
                  ),
                  keyboardType: TextInputType.number,
                ),
                DropdownButtonFormField<int>(
                  initialValue: background,
                  decoration: const InputDecoration(
                    labelText: 'Training background',
                  ),
                  items: [
                    for (final b in PhysicalConfig.trainingBackgrounds)
                      DropdownMenuItem(value: b, child: Text('$b')),
                  ],
                  onChanged: (v) => setS(() => background = v ?? background),
                ),
                DropdownButtonFormField<String>(
                  initialValue: typical,
                  decoration: const InputDecoration(labelText: 'Typical day'),
                  items: [
                    for (final t in PhysicalConfig.typicalDays)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) => setS(() => typical = v ?? typical),
                ),
                TextField(
                  controller: sleep,
                  decoration: const InputDecoration(
                    labelText: 'Sleep goal min (300–660)',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Write to device'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      final config = PhysicalConfig(
        gender: gender,
        birthDate: birth,
        height: double.tryParse(height.text) ?? 175,
        weight: double.tryParse(weight.text) ?? 70,
        maxHeartRate: int.tryParse(maxHr.text) ?? 190,
        vo2Max: int.tryParse(vo2.text) ?? 40,
        restingHeartRate: int.tryParse(restHr.text) ?? 60,
        trainingBackground: background,
        deviceTime: DateTime.now().toUtc().toIso8601String(),
        typicalDay: typical,
        sleepGoalMinutes: int.tryParse(sleep.text) ?? 480,
      );
      await _do(
        () => dc.bridge.doFirstTimeUse(id, config),
        success: 'Physical data written',
      );
    }
    for (final c in [height, weight, maxHr, restHr, vo2, sleep]) {
      c.dispose();
    }
  }
}
