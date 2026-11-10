import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../state/device_controller.dart';
import '../../state/sync_service.dart';
import '../scan_page.dart';
import '../settings/device_settings_page.dart';
import '../widgets/common.dart';
import 'format.dart';

/// Everything about the paired sensor: connection, sync, battery, storage
/// on the sensor, device information, and the phone's storage.
class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = appController;
    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _SensorCard(app.device, app.sync),
            if (app.settings.isPaired) _DeviceInfoCard(app.device, app.sync),
            _StorageCard(app.repo, refreshKey: app.sync.dataVersion),
          ],
        ),
      ),
    );
  }
}

/// Static facts about the sensor, kept from the last connection.
class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard(this.dc, this.sync);
  final DeviceController dc;
  final SyncService sync;

  String? _dis(String uuid) {
    for (final e in dc.disInfo.entries) {
      if (e.key.toLowerCase().startsWith(uuid)) return e.value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final settings = appController.settings;
    final disk = sync.diskSpace;
    final battery = dc.batteryLevel;
    final charge = switch (dc.chargeState) {
      'CHARGING' => ' · charging',
      'DISCHARGING_ACTIVE' || 'DISCHARGING_INACTIVE' => ' · on battery',
      _ => '',
    };
    return Section(
      title: 'Sensor details',
      children: [
        KeyValueList({
          'Name': settings.pairedName ?? '—',
          'ID': settings.pairedDeviceId ?? '—',
          'Address': settings.pairedAddress ?? '—',
          'Battery': battery == null ? '—' : '$battery%$charge',
          'Storage on sensor': disk == null
              ? '—'
              : '${formatBytes(disk.freeSpace)} free of ${formatBytes(disk.totalSpace)}',
          'Firmware': dc.firmwareVersion ?? '—',
          'Model': _dis('00002a24') ?? '—',
          'Serial': _dis('00002a25') ?? '—',
          'Hardware': _dis('00002a27') ?? '—',
          'Manufacturer': _dis('00002a29') ?? '—',
          'Last sync': sync.lastSyncAt == null
              ? 'never'
              : '${fmtAgo(sync.lastSyncAt)}'
                    '${sync.lastError == null ? '' : ' · ${sync.lastError}'}',
          'Scheduled sync': settings.syncEveryHours == 0
              ? 'off'
              : 'every ${settings.syncEveryHours} h',
          'Recording on sensor': settings.recordTypes
              .map((t) => t.label)
              .join(', '),
        }),
        if (!dc.isConnected)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Values from the last connection.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        ButtonRow([
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DeviceSettingsPage(),
              ),
            ),
            icon: const Icon(Icons.tune),
            label: const Text('Device settings'),
          ),
        ]),
      ],
    );
  }
}

class _SensorCard extends StatelessWidget {
  const _SensorCard(this.dc, this.sync);
  final DeviceController dc;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final settings = appController.settings;
    final scheme = Theme.of(context).colorScheme;
    if (!settings.isPaired) {
      return Section(
        title: 'Sensor',
        children: [
          const Text(
            'No sensor paired yet. Pair your Polar Verity Sense once; after that it '
            'connects on its own whenever it is on and in range.',
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const ScanPage())),
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Pair a sensor'),
          ),
        ],
      );
    }
    final (connLabel, connColor) = switch (dc.connection) {
      PolarConnectionState.connected => ('Connected', scheme.primary),
      PolarConnectionState.connecting => ('Connecting…', scheme.tertiary),
      PolarConnectionState.disconnected => ('Not connected', scheme.outline),
    };
    final busy = sync.isRunning;
    return Section(
      title: settings.pairedName ?? settings.pairedDeviceId!,
      trailing: dc.batteryLevel == null
          ? null
          : Text(
              '${dc.batteryLevel}%${dc.chargeState == 'CHARGING' ? ' ⚡' : ''}',
            ),
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: connColor),
            const SizedBox(width: 8),
            Text(connLabel),
            const Spacer(),
            if (dc.firmwareVersion != null)
              Text(
                'FW ${dc.firmwareVersion}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              switch (sync.phase) {
                SyncPhase.done => Icons.check_circle_outline,
                SyncPhase.error => Icons.error_outline,
                SyncPhase.idle || SyncPhase.waitingForDevice => Icons.schedule,
                _ => Icons.sync,
              },
              size: 18,
              color: sync.phase == SyncPhase.error ? scheme.error : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                switch (sync.phase) {
                  SyncPhase.idle => 'Idle',
                  SyncPhase.waitingForDevice => 'Waiting for the sensor',
                  SyncPhase.done =>
                    'Synced ${fmtAgo(sync.lastSyncAt)} · ${sync.detail}',
                  SyncPhase.error => 'Error: ${sync.detail}',
                  _ => sync.detail,
                },
                style: sync.phase == SyncPhase.error
                    ? TextStyle(color: scheme.error)
                    : null,
              ),
            ),
          ],
        ),
        if (busy) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: sync.progressPercent == null
                ? null
                : sync.progressPercent! / 100,
          ),
        ],
        if (!busy)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${settings.syncEveryHours == 0 ? 'No scheduled sync' : 'Syncs every ${settings.syncEveryHours} h'}'
              ' and when you open the app'
              '${sync.diskSpace == null ? '' : ' · sensor free ${formatBytes(sync.diskSpace!.freeSpace)}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        ButtonRow([
          FilledButton.icon(
            onPressed: busy || dc.connection == PolarConnectionState.connecting
                ? null
                : () => runAction(
                    context,
                    () => dc.isConnected
                        ? sync.syncNow(reason: 'manual')
                        : sync.connectAndSync(reason: 'manual'),
                  ),
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
          if (dc.connection != PolarConnectionState.disconnected)
            TextButton(
              onPressed: () => runAction(context, sync.disconnect),
              child: const Text('Disconnect'),
            ),
        ]),
      ],
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard(this.repo, {this.refreshKey});
  final Repository repo;
  final Object? refreshKey;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      key: ValueKey(refreshKey),
      future: Future.wait([
        repo.recordingCount(),
        repo.databaseSizeBytes(),
        repo.recordings(limit: 1),
      ]),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox.shrink();
        final count = d[0] as int;
        final size = d[1] as int;
        final latest = (d[2] as List<RecordingRow>).firstOrNull;
        return Section(
          title: 'Storage',
          children: [
            Text(
              '$count recording${count == 1 ? '' : 's'} · ${formatBytes(size)}'
              '${latest == null ? '' : ' · latest ${fmtMs(latest.startMs)}'}',
            ),
            Text(
              'Kept ${appController.settings.retentionDays} days once sent to mon.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}
