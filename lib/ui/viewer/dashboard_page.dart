import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../../state/sync_service.dart';
import '../scan_page.dart';
import '../widgets/common.dart';
import 'chart.dart';
import 'format.dart';

/// Status of sensor and sync, the live heart rate, and today's picture.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = appController;
    return Scaffold(
      appBar: AppBar(title: const Text('heild')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _SensorCard(app.device, app.sync),
            if (app.device.isConnected) _LiveHrCard(app.device),
            _TodayCard(app.repo, refreshKey: app.sync.lastSyncAt),
            _StorageCard(app.repo, refreshKey: app.sync.lastSyncAt),
          ],
        ),
      ),
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
        if (sync.nextRotationAt != null && !busy)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Next sync ${fmtTime.format(sync.nextRotationAt!)}'
              '${sync.diskSpace == null ? '' : ' · sensor free ${formatBytes(sync.diskSpace!.freeSpace)}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        ButtonRow([
          if (dc.isConnected)
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => runAction(
                      context,
                      () => sync.syncNow(reason: 'manual'),
                    ),
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            )
          else
            FilledButton.icon(
              onPressed: dc.connection == PolarConnectionState.connecting
                  ? null
                  : () => runAction(
                      context,
                      () => sync.connectAndSync(reason: 'manual'),
                    ),
              icon: const Icon(Icons.bluetooth_connected),
              label: const Text('Connect & sync'),
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

class _LiveHrCard extends StatelessWidget {
  const _LiveHrCard(this.dc);
  final DeviceController dc;

  @override
  Widget build(BuildContext context) {
    final active = dc.streams[PolarDataType.hr];
    final batch = active?.latest;
    HrSample? s;
    if (batch != null && batch.samples.isNotEmpty) {
      s = HrSample.fromMap(batch.samples.last);
    }
    s ??= dc.lastHrNotification;
    return Section(
      title: 'Live heart rate',
      trailing: active == null
          ? TextButton(
              onPressed: () =>
                  runAction(context, () => dc.startStream(PolarDataType.hr)),
              child: const Text('Start'),
            )
          : TextButton(
              onPressed: () =>
                  runAction(context, () => dc.stopStream(PolarDataType.hr)),
              child: const Text('Stop'),
            ),
      children: [
        if (s == null)
          const Text('Waiting for the first beat…')
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${s.hr}', style: Theme.of(context).textTheme.displayMedium),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'bpm${s.contactStatusSupported ? (s.contactStatus ? ' · on skin' : ' · no contact') : ''}'
                  '${s.rrAvailable && s.rrsMs.isNotEmpty ? ' · RR ${s.rrsMs.last} ms' : ''}',
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard(this.repo, {this.refreshKey});
  final Repository repo;
  final Object? refreshKey;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final from = day.millisecondsSinceEpoch;
    final to = from + 86400000;
    return FutureBuilder(
      key: ValueKey(refreshKey),
      future: Future.wait([
        repo.stats(PolarDataType.hr, from, to),
        repo.stats(PolarDataType.acc, from, to),
        repo.stats(PolarDataType.ppi, from, to),
      ]),
      builder: (context, snap) {
        final data = snap.data;
        final hr = data?[0] ?? const <StatBucket>[];
        final acc = data?[1] ?? const <StatBucket>[];
        final ppi = data?[2] ?? const <StatBucket>[];
        return Section(
          title: 'Today · ${fmtDate.format(day)}',
          children: [
            if (data == null)
              const LinearProgressIndicator()
            else if (hr.isEmpty && acc.isEmpty && ppi.isEmpty)
              const Text('Nothing recorded yet today.')
            else ...[
              if (hr.isNotEmpty) ...[
                _summaryRow(context, 'Heart rate', hr, 'bpm'),
                StatChart(
                  buckets: hr,
                  fromMs: from,
                  toMs: to,
                  bucketMs: 60000,
                  sparkline: true,
                  height: 60,
                ),
              ],
              if (ppi.isNotEmpty) ...[
                const SizedBox(height: 8),
                _summaryRow(context, 'HRV (RMSSD)', ppi, 'ms', extra: true),
              ],
              if (acc.isNotEmpty) ...[
                const SizedBox(height: 8),
                _summaryRow(
                  context,
                  'Movement',
                  acc,
                  'mG',
                  extra: true,
                  minutesLabel: true,
                ),
                StatChart(
                  buckets: acc,
                  fromMs: from,
                  toMs: to,
                  bucketMs: 60000,
                  field: StatField.extra,
                  sparkline: true,
                  height: 50,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _summaryRow(
    BuildContext context,
    String label,
    List<StatBucket> b,
    String unit, {
    bool extra = false,
    bool minutesLabel = false,
  }) {
    var n = 0;
    var sum = 0.0;
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final s in b) {
      final v = extra ? s.extra : s.mean;
      if (v == null) continue;
      n += s.n;
      sum += v * s.n;
      if (extra) {
        lo = lo > v ? v : lo;
        hi = hi < v ? v : hi;
      } else {
        lo = lo > s.min ? s.min : lo;
        hi = hi < s.max ? s.max : hi;
      }
    }
    final mean = n == 0 ? 0 : sum / n;
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          minutesLabel
              ? '${b.length} min recorded · avg ${mean.toStringAsFixed(0)} $unit'
              : '${lo.toStringAsFixed(0)} – ${hi.toStringAsFixed(0)} · avg ${mean.toStringAsFixed(0)} $unit',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
