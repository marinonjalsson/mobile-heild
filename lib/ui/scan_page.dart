import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart';
import '../polar/models.dart';
import '../polar/polar_bridge.dart';
import 'device_page.dart';
import 'widgets/common.dart';

/// Finds Polar devices and connects to one. Also listens to HR broadcasts,
/// which the SDK can do without a connection.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _bridge = PolarBridge.instance;
  final _found = <String, PolarDeviceInfo>{};
  StreamSubscription<PolarDeviceInfo>? _scan;
  StreamSubscription<HrBroadcast>? _broadcast;
  final _broadcasts = <String, HrBroadcast>{};
  String? _sdkVersion;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bridge
        .versionInfo()
        .then((v) => setState(() => _sdkVersion = v))
        .catchError((Object e) {
          setState(() => _error = '$e');
        });
  }

  @override
  void dispose() {
    _scan?.cancel();
    _broadcast?.cancel();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final ok = statuses.values.every((s) => s.isGranted);
    if (!ok && mounted) {
      setState(() => _error = 'Bluetooth permissions denied: $statuses');
    }
    return ok;
  }

  Future<void> _toggleScan() async {
    if (_scan != null) {
      await _scan!.cancel();
      setState(() => _scan = null);
      return;
    }
    if (!await _ensurePermissions()) return;
    setState(() {
      _found.clear();
      _error = null;
    });
    _scan = _bridge.search().listen(
      (d) => setState(() => _found[d.deviceId] = d),
      onError: (Object e) => setState(() {
        _error = '$e';
        _scan = null;
      }),
      onDone: () => setState(() => _scan = null),
    );
    setState(() {});
  }

  Future<void> _toggleBroadcast() async {
    if (_broadcast != null) {
      await _broadcast!.cancel();
      setState(() => _broadcast = null);
      return;
    }
    if (!await _ensurePermissions()) return;
    _broadcast = _bridge.hrBroadcasts().listen(
      (b) => setState(() => _broadcasts[b.device.deviceId] = b),
      onError: (Object e) => setState(() {
        _error = '$e';
        _broadcast = null;
      }),
    );
    setState(() {});
  }

  Future<void> _connect(String id) async {
    if (!await _ensurePermissions()) return;
    await _scan?.cancel();
    _scan = null;
    if (!mounted) return;
    final ok = await runAction(context, () => deviceController.connect(id));
    if (ok && mounted) {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const DevicePage()));
      setState(() {});
    }
  }

  Future<void> _connectById() async {
    final id = await promptText(
      context,
      title: 'Polar device ID',
      hint: 'e.g. C2E1A2B3 or 00:11:22:33:44:55',
    );
    if (id != null && id.trim().isNotEmpty)
      await _connect(id.trim().toUpperCase());
  }

  @override
  Widget build(BuildContext context) {
    final scanning = _scan != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('heild'),
        actions: [
          IconButton(
            tooltip: 'Connect by ID',
            icon: const Icon(Icons.keyboard),
            onPressed: _connectById,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: deviceController,
        builder: (context, _) {
          final dc = deviceController;
          return ListView(
            children: [
              if (dc.deviceId != null)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: ListTile(
                    leading: Icon(
                      dc.isConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                    ),
                    title: Text(dc.device?.name ?? dc.deviceId!),
                    subtitle: Text(dc.connection.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DevicePage(),
                      ),
                    ),
                  ),
                ),
              Section(
                title: 'Scan',
                trailing: FilledButton.icon(
                  onPressed: _toggleScan,
                  icon: scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(scanning ? 'Stop' : 'Scan'),
                ),
                children: [
                  if (_found.isEmpty)
                    Text(
                      scanning
                          ? 'Searching for Polar devices…'
                          : 'No devices yet. Wake the sensor and scan.',
                    ),
                  for (final d in _found.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.watch),
                      title: Text(d.name),
                      subtitle: Text(
                        '${d.deviceId} · ${d.address} · ${d.rssi} dBm',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: d.isConnectable
                            ? () => _connect(d.deviceId)
                            : null,
                        child: const Text('Connect'),
                      ),
                    ),
                ],
              ),
              Section(
                title: 'HR broadcasts (no connection)',
                trailing: Switch(
                  value: _broadcast != null,
                  onChanged: (_) => _toggleBroadcast(),
                ),
                children: [
                  if (_broadcasts.isEmpty)
                    const Text(
                      'Listens to heart rate in Polar BLE advertisements.',
                    ),
                  for (final b in _broadcasts.values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${b.device.name}  ${b.hr} bpm'),
                      subtitle: Text(
                        '${b.device.deviceId} · battery ${b.batteryStatus ? 'ok' : 'low'}',
                      ),
                    ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Polar BLE SDK ${_sdkVersion ?? '…'}',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
