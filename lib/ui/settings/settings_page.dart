import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/app_settings.dart';
import '../widgets/common.dart';
import '../viewer/format.dart';
import 'device_settings_page.dart';

/// Settings: Device (pairing, permissions, control panel), Recording, Storage, About.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = appController;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.settings;
          final dc = app.device;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: ListTile(
                  leading: const Icon(Icons.watch),
                  title: const Text('Device'),
                  subtitle: Text(
                    s.isPaired
                        ? '${s.pairedName ?? s.pairedDeviceId} · ${dc.isConnected ? 'connected' : 'not connected'}'
                        : 'No sensor paired',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DeviceSettingsPage(),
                    ),
                  ),
                ),
              ),
              _RecordingSection(s),
              _StorageSection(s),
              _AboutSection(),
            ],
          );
        },
      ),
    );
  }
}

class _RecordingSection extends StatelessWidget {
  const _RecordingSection(this.s);
  final AppSettings s;

  @override
  Widget build(BuildContext context) {
    return Section(
      title: 'Recording on the sensor',
      children: [
        Text(
          'The sensor records these on its own every time it is switched on. '
          'The phone fetches and clears them on each sync.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (final t in viewerTypes)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.label),
            subtitle: Text(switch (t) {
              PolarDataType.hr => '1 Hz, ~11 kB per hour',
              PolarDataType.ppi =>
                'pulse-to-pulse intervals for HRV, ~30 kB per hour',
              _ => 'movement, ~${(s.accRateHz / 50 * 600).round()} kB per hour',
            }),
            value: s.recordTypes.contains(t),
            onChanged: (v) {
              final set = {...s.recordTypes};
              v ? set.add(t) : set.remove(t);
              s.setRecordTypes(set);
            },
          ),
        if (s.recordTypes.contains(PolarDataType.acc))
          Row(
            children: [
              const Expanded(child: Text('Accelerometer')),
              DropdownButton<int>(
                value: s.accRateHz,
                items: const [13, 26, 52]
                    .map(
                      (v) => DropdownMenuItem(value: v, child: Text('$v Hz')),
                    )
                    .toList(),
                onChanged: (v) => s.setAcc(rateHz: v),
              ),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: s.accRangeG,
                items: const [2, 4, 8, 16]
                    .map(
                      (v) => DropdownMenuItem(value: v, child: Text('±$v g')),
                    )
                    .toList(),
                onChanged: (v) => s.setAcc(rangeG: v),
              ),
            ],
          ),
        Row(
          children: [
            const Expanded(child: Text('Sync while connected every')),
            DropdownButton<int>(
              value: s.rotationMinutes,
              items: const [15, 30, 60, 120, 240]
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(v < 60 ? '$v min' : '${v ~/ 60} h'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => v == null ? null : s.setRotationMinutes(v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: appController.device.isConnected
                ? () => runAction(
                    context,
                    () => appController.sync.syncNow(reason: 'settings'),
                    success: 'Sync started',
                  )
                : null,
            icon: const Icon(Icons.sync),
            label: const Text('Apply to sensor now'),
          ),
        ),
        if (!appController.device.isConnected)
          Text(
            'Changes are applied on the next sync.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _StorageSection extends StatefulWidget {
  const _StorageSection(this.s);
  final AppSettings s;

  @override
  State<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<_StorageSection> {
  int? _size;
  int? _count;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final repo = appController.repo;
    final size = await repo.databaseSizeBytes();
    final count = await repo.recordingCount();
    if (mounted) {
      setState(() {
        _size = size;
        _count = count;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Section(
      title: 'Storage on the phone',
      children: [
        Text(
          '${_count ?? '…'} recordings · ${_size == null ? '…' : formatBytes(_size!)}',
        ),
        Row(
          children: [
            const Expanded(
              child: Text('Delete recordings older than, once sent to mon'),
            ),
            DropdownButton<int>(
              value: s.retentionDays,
              items: const [7, 14, 30, 60, 90, 365]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v d')))
                  .toList(),
              onChanged: (v) => v == null ? null : s.setRetentionDays(v),
            ),
          ],
        ),
        ButtonRow([
          OutlinedButton(
            onPressed: () => runAction(context, () async {
              final n = await appController.repo.retention(
                days: s.retentionDays,
              );
              await _refresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Removed $n recordings')),
                );
              }
            }),
            child: const Text('Run retention now'),
          ),
          OutlinedButton(
            onPressed: () => runAction(context, () async {
              await appController.repo.vacuum();
              await _refresh();
            }, success: 'Database compacted'),
            child: const Text('Compact database'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SyncLogPage()),
            ),
            child: const Text('Sync log'),
          ),
        ]),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: appController.device.bridge.versionInfo(),
      builder: (context, snap) => Section(
        title: 'About',
        children: [
          KeyValueList({
            'App': 'heild 1.0.0',
            'Polar BLE SDK': snap.data ?? '…',
            'Data goes to': 'this phone (MQTT to mon later)',
          }),
        ],
      ),
    );
  }
}

/// What the sync did, newest first.
class SyncLogPage extends StatelessWidget {
  const SyncLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync log')),
      body: FutureBuilder(
        future: appController.repo.syncLog(limit: 500),
        builder: (context, snap) {
          final rows = snap.data;
          if (rows == null) return const LinearProgressIndicator();
          if (rows.isEmpty) return const Center(child: Text('Nothing yet.'));
          final scheme = Theme.of(context).colorScheme;
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final r = rows[i];
              return SelectableText(
                '${fmtMs(r.tsMs)}  ${r.message}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: switch (r.level) {
                    'error' => scheme.error,
                    'warn' => scheme.tertiary,
                    _ => null,
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
