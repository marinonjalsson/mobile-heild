import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../widgets/common.dart';
import 'settings_sheet.dart';

/// Online streaming: one card per data type the device offers.
class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> with AutomaticKeepAliveClientMixin {
  List<PolarDataType>? _types;
  final _settings = <PolarDataType, SensorSetting>{};
  bool _loading = false;
  bool _autoLoaded = false;

  @override
  bool get wantKeepAlive => true;

  DeviceController get dc => deviceController;

  Future<void> _loadTypes() async {
    final id = dc.deviceId;
    if (id == null) return;
    setState(() => _loading = true);
    await runAction(context, () async {
      final types = await dc.bridge.availableOnlineStreamDataTypes(id);
      // HR via the standard service is listed separately by the SDK.
      if (!types.contains(PolarDataType.hr)) {
        try {
          types.addAll(await dc.bridge.availableHrServiceDataTypes(id));
        } catch (_) {}
      }
      types.sort((a, b) => a.index.compareTo(b.index));
      setState(() => _types = types);
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _start(PolarDataType type) async {
    SensorSetting? settings;
    if (type.needsSettings) {
      settings = _settings[type] ?? await _pick(type);
      if (settings == null) return;
    }
    if (!mounted) return;
    await runAction(context, () => dc.startStream(type, settings: settings));
  }

  Future<SensorSetting?> _pick(PolarDataType type) async {
    final id = dc.deviceId!;
    final picked = await pickSensorSettings(
      context,
      title: '${type.label} settings',
      initial: _settings[type],
      load: (full) => full
          ? dc.bridge.requestFullStreamSettings(id, type)
          : dc.bridge.requestStreamSettings(id, type),
    );
    if (picked != null) setState(() => _settings[type] = picked);
    return picked;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: dc,
      builder: (context, _) {
        final ready = dc.featuresReady.contains(
          'FEATURE_POLAR_ONLINE_STREAMING',
        );
        if (ready && _types == null && !_loading && !_autoLoaded) {
          _autoLoaded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadTypes());
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Section(
              title: 'Streams',
              trailing: ButtonRow([
                if (dc.streams.isNotEmpty)
                  TextButton(
                    onPressed: () => runAction(context, dc.stopAllStreams),
                    child: const Text('Stop all'),
                  ),
                IconButton(
                  tooltip: 'Reload available types',
                  onPressed: ready && !_loading ? _loadTypes : null,
                  icon: const Icon(Icons.refresh),
                ),
              ]),
              children: [
                if (!dc.isConnected)
                  const Text('Not connected.')
                else if (!ready)
                  const Text(
                    'Waiting for the streaming feature to become ready…',
                  )
                else if (_loading)
                  const LinearProgressIndicator()
                else if (_types == null || _types!.isEmpty)
                  const Text('No stream types reported.'),
                if (dc.lastHrNotification != null)
                  Text(
                    'HR service notification: ${dc.lastHrNotification!.hr} bpm',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            for (final type in _types ?? const <PolarDataType>[])
              _StreamCard(
                type: type,
                active: dc.streams[type],
                lastError: dc.streamErrors[type],
                settings: _settings[type],
                enabled: dc.isConnected,
                onStart: () => _start(type),
                onStop: () => runAction(context, () => dc.stopStream(type)),
                onSettings: type.needsSettings ? () => _pick(type) : null,
              ),
          ],
        );
      },
    );
  }
}

class _StreamCard extends StatelessWidget {
  const _StreamCard({
    required this.type,
    required this.active,
    this.lastError,
    required this.settings,
    required this.enabled,
    required this.onStart,
    required this.onStop,
    this.onSettings,
  });

  final PolarDataType type;
  final ActiveStream? active;
  final Object? lastError;
  final SensorSetting? settings;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final a = active;
    final running = a != null;
    return Section(
      title: type.label,
      trailing: ButtonRow([
        if (onSettings != null)
          IconButton(
            tooltip: 'Settings',
            onPressed: enabled && !running ? onSettings : null,
            icon: const Icon(Icons.tune),
          ),
        running
            ? FilledButton.tonal(onPressed: onStop, child: const Text('Stop'))
            : FilledButton(
                onPressed: enabled ? onStart : null,
                child: const Text('Start'),
              ),
      ]),
      children: [
        if (settings != null && type.needsSettings)
          Text(
            settings.toString(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (a == null) ...[
          Text(
            type == PolarDataType.ppi
                ? 'First PPI batch arrives after ~25 s. HR is then updated every 5 s.'
                : 'Not running.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (lastError != null)
            Text(
              '$lastError',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ] else ...[
          if (a.error != null)
            Text(
              '${a.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          _LatestValues(a),
          const SizedBox(height: 6),
          Text(
            'batches ${a.batches} · samples ${a.samples} · ${a.samplesPerSecond.toStringAsFixed(1)}/s',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _LatestValues extends StatelessWidget {
  const _LatestValues(this.active);
  final ActiveStream active;

  @override
  Widget build(BuildContext context) {
    final batch = active.latest;
    final big = Theme.of(context).textTheme.displaySmall;
    final mono = const TextStyle(fontFamily: 'monospace');
    if (batch == null || batch.samples.isEmpty) {
      return const Text('Waiting for data…');
    }
    final last = batch.samples.last;
    switch (active.type) {
      case PolarDataType.hr:
        final s = HrSample.fromMap(last);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.hr} bpm', style: big),
            Text(
              'RR ${s.rrAvailable ? s.rrsMs.join(', ') : '—'} ms'
              '${s.contactStatusSupported ? ' · contact ${s.contactStatus ? 'yes' : 'no'}' : ''}'
              '${s.correctedHr != 0 ? ' · corrected ${s.correctedHr}' : ''}'
              '${s.ppgQuality != 0 ? ' · quality ${s.ppgQuality}' : ''}',
              style: mono,
            ),
          ],
        );
      case PolarDataType.ppi:
        final s = PpiSample.fromMap(last);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.ppi} ms', style: big),
            Text(
              'hr ${s.hr} · error ±${s.errorEstimate} ms · blocker ${s.blockerBit ? 'yes' : 'no'}'
              '${s.skinContactSupported ? ' · skin ${s.skinContactStatus ? 'yes' : 'no'}' : ''}'
              '\nlast batch: ${batch.samples.map((m) => m['ppi']).join(', ')}',
              style: mono,
            ),
          ],
        );
      case PolarDataType.acc:
      case PolarDataType.gyro:
      case PolarDataType.magnetometer:
        final s = XyzSample.fromMap(last);
        final unit = switch (active.type) {
          PolarDataType.acc => 'mG',
          PolarDataType.gyro => 'deg/s',
          _ => 'G',
        };
        String f(double v) => active.type == PolarDataType.acc
            ? v.toStringAsFixed(0)
            : v.toStringAsFixed(3);
        return Text(
          'x ${f(s.x)}\ny ${f(s.y)}\nz ${f(s.z)}  $unit\nts ${s.timeStamp}',
          style: mono.copyWith(fontSize: 16),
        );
      case PolarDataType.ppg:
        final s = PpgSample.fromMap(last);
        return Text(
          'type ${batch.ppgDataType}\nchannels ${s.channelSamples.join('  ')}\nstatus ${s.statusBits.join(' ')}\nts ${s.timeStamp}',
          style: mono,
        );
      default:
        return Text(last.toString(), style: mono);
    }
  }
}
