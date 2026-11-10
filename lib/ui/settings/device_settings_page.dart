import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../main.dart';
import '../../state/device_controller.dart';
import '../device_page.dart';
import '../scan_page.dart';
import '../widgets/common.dart';

/// The paired sensor, the Android plumbing that lets it wake the app, and the
/// door to the full control panel.
class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage>
    with WidgetsBindingObserver {
  bool? _associated;
  bool? _batteryOk;
  PermissionStatus? _notifications;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final bridge = appController.device.bridge;
    final id = appController.settings.pairedDeviceId;
    bool? assoc;
    if (id != null) {
      try {
        assoc = await bridge.companionIsAssociated(id);
      } catch (_) {}
    }
    bool? battery;
    try {
      battery = await bridge.isIgnoringBatteryOptimizations();
    } catch (_) {}
    final notif = await Permission.notification.status;
    if (mounted) {
      setState(() {
        _associated = assoc;
        _batteryOk = battery;
        _notifications = notif;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = appController;
    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final dc = app.device;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Section(
                title: 'Paired sensor',
                children: [
                  if (!s.isPaired) ...[
                    const Text('None. Pair the Verity Sense you wear.'),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => _openScan(context),
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text('Pair a sensor'),
                    ),
                  ] else ...[
                    KeyValueList({
                      'Name': s.pairedName,
                      'Device ID': s.pairedDeviceId,
                      'Address': s.pairedAddress,
                      'Connection': switch (dc.connection) {
                        PolarConnectionState.connected => 'connected',
                        PolarConnectionState.connecting => 'connecting…',
                        PolarConnectionState.disconnected =>
                          'not connected${dc.lastDisconnect == null ? '' : ' (${dc.lastDisconnect!.reason})'}',
                      },
                      'Android companion': switch (_associated) {
                        null => 'unknown',
                        true => 'associated · wakes heild when in range',
                        false => 'not yet · connect once and accept the Android dialog',
                      },
                    }),
                    const SizedBox(height: 8),
                    ButtonRow([
                      if (dc.isConnected)
                        OutlinedButton(
                          onPressed: () =>
                              runAction(context, app.sync.disconnect),
                          child: const Text('Disconnect'),
                        )
                      else
                        FilledButton(
                          onPressed: () => runAction(
                            context,
                            () => app.sync.connectAndSync(reason: 'settings'),
                          ),
                          child: const Text('Connect'),
                        ),
                      OutlinedButton(
                        onPressed: dc.deviceId == null
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const DevicePage(),
                                ),
                              ),
                        child: const Text('Control panel'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final ok = await confirmSimple(
                            context,
                            title: 'Unpair sensor?',
                            body:
                                'heild stops connecting automatically and removes the '
                                'Android companion association. Stored data stays.',
                          );
                          if (ok && context.mounted) {
                            await runAction(context, app.unpair);
                            await _refresh();
                          }
                        },
                        child: const Text('Unpair'),
                      ),
                    ]),
                  ],
                ],
              ),
              Section(
                title: 'Connection',
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'The phone connects for a sync on the schedule (Settings), '
                      'when you open the app, on "Sync now" and for a live '
                      'session; it disconnects afterwards.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Also sync when the sensor comes into range',
                    ),
                    subtitle: const Text(
                      'Android wakes heild when the sensor is switched on nearby',
                    ),
                    value: s.autoSync,
                    onChanged: s.setAutoSync,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => runAction(context, () async {
                        await app.device.bridge.scheduleSyncIn(30);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Scheduled sync fires in 30 s. Leave the app to test '
                                'the background path; see the sync log.',
                              ),
                            ),
                          );
                        }
                      }),
                      icon: const Icon(Icons.alarm),
                      label: const Text('Test the scheduled sync (30 s)'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pulse quality during a live session'),
                    subtitle: const Text(
                      'Streams PP intervals to the phone (stored here) instead of '
                      'recording them on the sensor; the sensor records them again '
                      'when the session ends.',
                    ),
                    value: s.livePpi,
                    onChanged: s.setLivePpi,
                  ),
                ],
              ),
              Section(
                title: 'Android permissions',
                children: [
                  _PermRow(
                    label: 'Notifications',
                    ok: _notifications?.isGranted,
                    detail: 'Shows the sync status while connected in the background',
                    onFix: () async {
                      await Permission.notification.request();
                      await _refresh();
                    },
                  ),
                  _PermRow(
                    label: 'Battery optimisation off',
                    ok: _batteryOk,
                    detail:
                        'Lets Android keep heild alive while syncing. On Samsung also add '
                        'heild to "Never sleeping apps".',
                    onFix: () => runAction(
                      context,
                      app.device.bridge.requestIgnoreBatteryOptimizations,
                    ),
                  ),
                  _PermRow(
                    label: 'Companion background privilege',
                    ok: null,
                    detail: 'Optional: relaxes background limits for companion apps (Android dialog).',
                    onFix: () => runAction(context, () async {
                      final ok = await app.device.bridge
                          .companionRequestBackgroundPrivilege();
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Needs an associated sensor and the app in the foreground',
                            ),
                          ),
                        );
                      }
                    }),
                  ),
                ],
              ),
              Section(
                title: 'Manual',
                children: [
                  ButtonRow([
                    OutlinedButton.icon(
                      onPressed: () => _openScan(context),
                      icon: const Icon(Icons.search),
                      label: const Text('Scan / connect manually'),
                    ),
                  ]),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openScan(BuildContext context) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ScanPage()));
    await _refresh();
  }
}

class _PermRow extends StatelessWidget {
  const _PermRow({
    required this.label,
    required this.ok,
    required this.detail,
    required this.onFix,
  });
  final String label;
  final bool? ok;
  final String detail;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ok == null
            ? Icons.help_outline
            : ok!
            ? Icons.check_circle
            : Icons.warning_amber,
        color: ok == null
            ? scheme.outline
            : ok!
            ? scheme.primary
            : scheme.error,
      ),
      title: Text(label),
      subtitle: Text(detail),
      trailing: ok == true
          ? null
          : TextButton(onPressed: onFix, child: const Text('Fix')),
    );
  }
}
