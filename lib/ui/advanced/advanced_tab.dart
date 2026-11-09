import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../widgets/common.dart';

/// Firmware, raw file system, device logs, telemetry, device-to-host
/// notifications and SDK connection settings.
class AdvancedTab extends StatefulWidget {
  const AdvancedTab({super.key});

  @override
  State<AdvancedTab> createState() => _AdvancedTabState();
}

class _AdvancedTabState extends State<AdvancedTab>
    with AutomaticKeepAliveClientMixin {
  FirmwareCheck? _fwCheck;
  final _fwStatus = <FirmwareUpdateStatus>[];
  StreamSubscription<FirmwareUpdateStatus>? _fwSub;
  final _fwUrl = TextEditingController();

  final _path = TextEditingController(text: '/');
  List<String>? _files;
  bool _recurse = false;

  List<DeviceLog>? _logs;
  Map<Object?, Object?>? _logConfig;

  Map<Object?, Object?>? _telemetryTypes;
  StreamSubscription<Map<Object?, Object?>>? _telemetrySub;
  int _telemetryEvents = 0;
  String? _telemetryLast;

  StreamSubscription<Map<Object?, Object?>>? _d2hSub;
  final _d2h = <String>[];

  final _mtu = TextEditingController(text: '232');
  bool _polarFilter = true;
  bool _autoReconnect = true;

  @override
  bool get wantKeepAlive => true;

  DeviceController get dc => deviceController;
  String get id => dc.deviceId!;

  @override
  void dispose() {
    _fwSub?.cancel();
    _telemetrySub?.cancel();
    _d2hSub?.cancel();
    for (final c in [_fwUrl, _path, _mtu]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> _do(Future<void> Function() f, {String? success}) =>
      runAction(context, f, success: success);

  Future<void> _info(String title, String text) async {
    if (!mounted) return;
    await showTextDialog(context, title, text);
  }

  Future<void> _checkFirmware() async {
    setState(() => _fwCheck = null);
    await _do(() async {
      final first = await dc.bridge.checkFirmwareUpdate(id).first;
      setState(() => _fwCheck = first);
    });
  }

  Future<void> _updateFirmware() async {
    final url = _fwUrl.text.trim();
    final ok = await confirmTyped(
      context,
      title: 'Update firmware',
      body:
          'The update erases ALL data on the sensor, including offline recordings. '
          'Keep the sensor near the phone and charged. ${url.isEmpty ? 'Latest Polar firmware will be used.' : 'Firmware: $url'}',
      word: 'UPDATE',
    );
    if (!ok) return;
    setState(_fwStatus.clear);
    _fwSub = dc.bridge
        .updateFirmware(id, firmwareUrl: url.isEmpty ? null : url)
        .listen(
          (s) => setState(() => _fwStatus.add(s)),
          onError: (Object e) => setState(
            () => _fwStatus.add(
              FirmwareUpdateStatus.fromMap({
                'status': 'Error',
                'details': '$e',
              }),
            ),
          ),
          onDone: () => setState(() => _fwSub = null),
        );
    setState(() {});
  }

  Future<void> _listFiles() async {
    await _do(() async {
      final f = await dc.bridge.getFileList(
        id,
        _path.text.trim(),
        recurseDeep: _recurse,
      );
      setState(() => _files = f);
    });
  }

  Future<void> _readFile(String path) async {
    await _do(() async {
      final bytes = await dc.bridge.readFile(id, path);
      if (!mounted) return;
      if (bytes == null) {
        await showTextDialog(context, path, '(empty)');
        return;
      }
      final hex = bytes
          .take(512)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      String text;
      try {
        text = utf8.decode(bytes, allowMalformed: false);
      } catch (_) {
        text = '(binary)';
      }
      await showTextDialog(
        context,
        '$path (${formatBytes(bytes.length)})',
        'hex${bytes.length > 512 ? ' (first 512 bytes)' : ''}:\n$hex\n\ntext:\n$text',
      );
    });
  }

  Future<void> _writeFile() async {
    final path = await promptText(
      context,
      title: 'File path to write',
      hint: '/TEST.TXT',
      initial: _path.text,
    );
    if (path == null || path.isEmpty || !mounted) return;
    final content = await promptText(context, title: 'Text content for $path');
    if (content == null || !mounted) return;
    await _do(
      () => dc.bridge.writeFile(
        id,
        path,
        Uint8List.fromList(utf8.encode(content)),
      ),
      success: 'Written',
    );
  }

  Future<void> _deletePath(String path) async {
    if (!await confirmTyped(
      context,
      title: 'Delete on device',
      body: path,
      word: 'DELETE',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await _do(
      () => dc.bridge.deleteFileOrDirectory(id, path),
      success: 'Deleted',
    );
    if (ok) setState(() => _files?.remove(path));
  }

  Future<void> _toggleTelemetry(String type) async {
    if (_telemetrySub != null) {
      await _telemetrySub!.cancel();
      await _do(() => dc.bridge.stopTelemetry(id, type));
      setState(() => _telemetrySub = null);
      return;
    }
    _telemetryEvents = 0;
    _telemetrySub = dc.bridge
        .startTelemetry(id, type)
        .listen(
          (e) => setState(() {
            _telemetryEvents++;
            _telemetryLast =
                '${e['type']}: ${(e['payload'] as List?)?.length ?? 0} bytes';
          }),
          onError: (Object e) => setState(() {
            _telemetryLast = '$e';
            _telemetrySub = null;
          }),
          onDone: () => setState(() => _telemetrySub = null),
        );
    setState(() {});
  }

  void _toggleD2h(bool on) {
    if (!on) {
      _d2hSub?.cancel();
      setState(() => _d2hSub = null);
      return;
    }
    _d2hSub = dc.bridge
        .d2hNotifications(id)
        .listen(
          (n) => setState(
            () => _d2h.insert(
              0,
              '${n['notificationType']} ${n['parsedParameters'] ?? ''}',
            ),
          ),
          onError: (Object e) => setState(() {
            _d2h.insert(0, 'error: $e');
            _d2hSub = null;
          }),
          onDone: () => setState(() => _d2hSub = null),
        );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: dc,
      builder: (context, _) {
        final on = dc.isConnected;
        final fw =
            on && dc.featuresReady.contains('FEATURE_POLAR_FIRMWARE_UPDATE');
        final fs =
            on && dc.featuresReady.contains('FEATURE_POLAR_FILE_TRANSFER');
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Section(
              title: 'Firmware',
              trailing: TextButton(
                onPressed: fw ? _checkFirmware : null,
                child: const Text('Check'),
              ),
              children: [
                if (_fwCheck != null)
                  Text(switch (_fwCheck!.status) {
                    'available' =>
                      'Update available: ${_fwCheck!.version}${_fwCheck!.mandatoryUpdate == true ? ' (mandatory)' : ''}',
                    'notAvailable' =>
                      'No update available. ${_fwCheck!.details ?? ''}',
                    _ => 'Check failed: ${_fwCheck!.details}',
                  }),
                TextField(
                  controller: _fwUrl,
                  decoration: const InputDecoration(
                    labelText: 'Custom firmware URL (optional)',
                  ),
                ),
                const SizedBox(height: 8),
                ButtonRow([
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: fw && _fwSub == null ? _updateFirmware : null,
                    child: Text(
                      _fwSub == null ? 'Update firmware' : 'Updating…',
                    ),
                  ),
                ]),
                for (final s in _fwStatus)
                  Text(
                    '${s.status} ${s.details}',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            Section(
              title: 'File system',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _path,
                        decoration: const InputDecoration(labelText: 'Path'),
                      ),
                    ),
                    Checkbox(
                      value: _recurse,
                      onChanged: (v) => setState(() => _recurse = v ?? false),
                    ),
                    const Text('deep'),
                  ],
                ),
                ButtonRow([
                  FilledButton.tonal(
                    onPressed: fs ? _listFiles : null,
                    child: const Text('List'),
                  ),
                  TextButton(
                    onPressed: fs ? _writeFile : null,
                    child: const Text('Write text file…'),
                  ),
                  TextButton(
                    onPressed: !fs
                        ? null
                        : () async {
                            final p = await promptText(
                              context,
                              title: 'New folder path',
                              hint: '/NEWDIR/',
                            );
                            if (p != null && p.isNotEmpty && mounted) {
                              await _do(
                                () => dc.bridge.createFolder(id, p),
                                success: 'Folder created',
                              );
                            }
                          },
                    child: const Text('Create folder…'),
                  ),
                ]),
                if (_files != null && _files!.isEmpty) const Text('Empty.'),
                for (final f in _files ?? const <String>[])
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      f,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    onTap: f.endsWith('/')
                        ? () => setState(() => _path.text = f)
                        : () => _readFile(f),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deletePath(f),
                    ),
                  ),
              ],
            ),
            Section(
              title: 'Device logs',
              trailing: ButtonRow([
                TextButton(
                  onPressed: !fs
                      ? null
                      : () => _do(() async {
                          final l = await dc.bridge.exportDeviceLogs(id);
                          setState(() => _logs = l);
                        }),
                  child: const Text('Export'),
                ),
                TextButton(
                  onPressed: !fs
                      ? null
                      : () => _do(() async {
                          final c = await dc.bridge.getLogConfig(id);
                          setState(() => _logConfig = c);
                        }),
                  child: const Text('Log config'),
                ),
              ]),
              children: [
                if (_logs != null) Text('${_logs!.length} log file(s)'),
                for (final l in _logs ?? const <DeviceLog>[])
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.path,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    subtitle: Text(formatBytes(l.size)),
                    onTap: () => showTextDialog(
                      context,
                      l.path,
                      utf8.decode(l.data, allowMalformed: true),
                    ),
                  ),
                if (_logConfig != null) ...[
                  const Divider(),
                  for (final e in _logConfig!.entries)
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${e.key}'),
                      subtitle: e.value == null ? const Text('not set') : null,
                      value: e.value == true,
                      onChanged: (v) => setState(() => _logConfig![e.key] = v),
                    ),
                  ButtonRow([
                    FilledButton.tonal(
                      onPressed: () => _do(
                        () => dc.bridge.setLogConfig(id, {
                          for (final e in _logConfig!.entries)
                            '${e.key}': e.value as bool?,
                        }),
                        success: 'Log config written',
                      ),
                      child: const Text('Write log config'),
                    ),
                  ]),
                ],
              ],
            ),
            Section(
              title: 'Telemetry (Memfault MDS)',
              trailing: TextButton(
                onPressed: !on
                    ? null
                    : () => _do(() async {
                        final t = await dc.bridge.getAvailableTelemetryTypes(
                          id,
                        );
                        setState(() => _telemetryTypes = t);
                      }),
                child: const Text('Types'),
              ),
              children: [
                if (_telemetryTypes != null)
                  Text(
                    'Available: ${_telemetryTypes!['availableTelemetryTypes']}',
                  ),
                ButtonRow([
                  FilledButton.tonal(
                    onPressed: !on
                        ? null
                        : () => _toggleTelemetry('memfault_mds'),
                    child: Text(
                      _telemetrySub == null ? 'Start memfault_mds' : 'Stop',
                    ),
                  ),
                  TextButton(
                    onPressed: !on
                        ? null
                        : () => _do(() async {
                            final c = await dc.bridge
                                .getDeviceTelemetryConfiguration(
                                  id,
                                  'memfault_mds',
                                );
                            await _info('Telemetry configuration', '$c');
                          }),
                    child: const Text('Configuration'),
                  ),
                ]),
                if (_telemetrySub != null || _telemetryLast != null)
                  Text(
                    'events: $_telemetryEvents · last: ${_telemetryLast ?? '—'}',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            Section(
              title: 'Device-to-host notifications',
              trailing: Switch(
                value: _d2hSub != null,
                onChanged: on ? _toggleD2h : null,
              ),
              children: [
                if (_d2h.isEmpty)
                  const Text(
                    'Filesystem modified, battery status, sync required…',
                  ),
                for (final n in _d2h.take(20))
                  Text(
                    n,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
            Section(
              title: 'SDK connection settings',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Polar filter in scan'),
                  subtitle: const Text(
                    'Off: any BLE heart-rate device is listed',
                  ),
                  value: _polarFilter,
                  onChanged: (v) => _do(() async {
                    await dc.bridge.setPolarFilter(v);
                    setState(() => _polarFilter = v);
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic reconnection'),
                  value: _autoReconnect,
                  onChanged: (v) => _do(() async {
                    await dc.bridge.setAutomaticReconnection(v);
                    setState(() => _autoReconnect = v);
                  }),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _mtu,
                        decoration: const InputDecoration(
                          labelText: 'MTU (70–512)',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _do(
                        () => dc.bridge.setMtu(int.tryParse(_mtu.text) ?? 232),
                        success: 'MTU set',
                      ),
                      child: const Text('Set MTU'),
                    ),
                  ],
                ),
                ButtonRow([
                  TextButton(
                    onPressed: () => _do(
                      dc.bridge.foregroundEntered,
                      success: 'foregroundEntered sent',
                    ),
                    child: const Text('Foreground entered'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _do(dc.bridge.cleanup, success: 'cleanup done'),
                    child: const Text('Cleanup'),
                  ),
                  TextButton(
                    onPressed: dc.deviceId == null
                        ? null
                        : () => _do(() async {
                            final r = await dc.bridge
                                .checkIfDisconnectedDueRemovedPairing(id);
                            await _info('Removed pairing check', '$r');
                          }),
                    child: const Text('Pairing check'),
                  ),
                  TextButton(
                    onPressed: dc.deviceId == null
                        ? null
                        : () => _do(
                            () => dc.bridge.waitForConnection(id),
                            success: 'Connected',
                          ),
                    child: const Text('Wait for connection'),
                  ),
                  TextButton(
                    onPressed: !on
                        ? null
                        : () => _do(() async {
                            final n = await dc.bridge.getDeviceName(id);
                            final b = await dc.bridge.getBatteryLevel(id);
                            final c = await dc.bridge.getChargerState(id);
                            await _info(
                              'Cached values',
                              'name: $n\nbattery: $b\ncharger: $c',
                            );
                          }),
                    child: const Text('Cached values'),
                  ),
                ]),
              ],
            ),
          ],
        );
      },
    );
  }
}
