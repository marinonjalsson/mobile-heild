import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../polar/models.dart';
import '../../state/device_controller.dart';
import '../live/settings_sheet.dart';
import '../widgets/common.dart';

/// Offline recording: record to device memory, triggers, list/fetch/delete recordings.
class OfflineTab extends StatefulWidget {
  const OfflineTab({super.key});

  @override
  State<OfflineTab> createState() => _OfflineTabState();
}

class _OfflineTabState extends State<OfflineTab>
    with AutomaticKeepAliveClientMixin {
  List<PolarDataType>? _types;
  List<PolarDataType> _recording = const [];
  final _settings = <PolarDataType, SensorSetting>{};
  List<OfflineRecordingEntry>? _entries;
  bool _listing = false;
  OfflineRecordingTrigger? _trigger;
  TriggerMode _triggerMode = TriggerMode.disabled;
  final Set<PolarDataType> _triggerTypes = {};
  final _secret = TextEditingController();
  bool _autoLoaded = false;

  @override
  bool get wantKeepAlive => true;

  DeviceController get dc => deviceController;
  String? get id => dc.deviceId;
  String? get _secretHex =>
      _secret.text.trim().isEmpty ? null : _secret.text.trim();

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final i = id;
    if (i == null) return;
    await runAction(context, () async {
      final types = await dc.bridge.availableOfflineRecordingDataTypes(i);
      types.sort((a, b) => a.index.compareTo(b.index));
      final status = await dc.bridge.offlineRecordingStatus(i);
      setState(() {
        _types = types;
        _recording = status;
      });
    });
  }

  Future<void> _start(PolarDataType type) async {
    final i = id!;
    SensorSetting? settings;
    if (type.needsSettings) {
      settings =
          _settings[type] ??
          await pickSensorSettings(
            context,
            title: '${type.label} recording settings',
            load: (full) => full
                ? dc.bridge.requestFullOfflineRecordingSettings(i, type)
                : dc.bridge.requestOfflineRecordingSettings(i, type),
          );
      if (settings == null) return;
      _settings[type] = settings;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => dc.bridge.startOfflineRecording(
        i,
        type,
        settings: settings,
        secretHex: _secretHex,
      ),
      success: '${type.label} recording started',
    );
    if (ok) await _refresh();
  }

  Future<void> _stop(PolarDataType type) async {
    final ok = await runAction(
      context,
      () => dc.bridge.stopOfflineRecording(id!, type),
      success: '${type.label} recording stopped',
    );
    if (ok) await _refresh();
  }

  Future<void> _list() async {
    final i = id;
    if (i == null) return;
    setState(() {
      _listing = true;
      _entries = [];
    });
    final done = Completer<void>();
    dc.bridge
        .listOfflineRecordings(i)
        .listen(
          (e) => setState(() => _entries = [..._entries!, e]),
          onError: (Object e) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('$e')));
            }
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
    await done.future;
    if (mounted) setState(() => _listing = false);
  }

  Future<void> _fetch(OfflineRecordingEntry entry) async {
    final i = id!;
    final progress = ValueNotifier<OfflineFetchEvent?>(null);
    StreamSubscription<OfflineFetchEvent>? sub;
    Object? error;
    final finished = Completer<void>();
    sub = dc.bridge
        .fetchOfflineRecording(i, entry, secretHex: _secretHex)
        .listen(
          (e) => progress.value = e,
          onError: (Object e) {
            error = e;
            if (!finished.isCompleted) finished.complete();
          },
          onDone: () {
            if (!finished.isCompleted) finished.complete();
          },
        );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        finished.future.then((_) {
          if (ctx.mounted && progress.value?.data == null) {
            Navigator.of(ctx).pop();
          }
        });
        return ValueListenableBuilder<OfflineFetchEvent?>(
          valueListenable: progress,
          builder: (ctx, ev, _) {
            final data = ev?.data;
            if (data != null) {
              return AlertDialog(
                title: Text('${data.type} recording'),
                content: SingleChildScrollView(
                  child: KeyValueList({
                    'Start': data.startTime.toString(),
                    'Settings': data.settings == null || data.settings!.isEmpty
                        ? '—'
                        : data.settings!.defaults().toString(),
                    'Samples': '${data.sampleCount}',
                    'First': data.first?.toString(),
                    'Last': data.last?.toString(),
                    'File': entry.path,
                    'Size': formatBytes(entry.size),
                  }),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              );
            }
            final pct = ev?.progressPercent;
            return AlertDialog(
              title: const Text('Fetching recording'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: pct == null ? null : pct / 100,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ev == null
                        ? 'Starting…'
                        : '${formatBytes(ev.bytesDownloaded ?? 0)} / ${formatBytes(ev.totalBytes ?? 0)} ($pct%)',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    sub?.cancel();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );
    await sub.cancel();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _delete(OfflineRecordingEntry entry) async {
    if (!await confirmSimple(
      context,
      title: 'Delete recording?',
      body: entry.path,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => dc.bridge.removeOfflineRecord(id!, entry),
      success: 'Deleted',
    );
    if (ok) setState(() => _entries?.remove(entry));
  }

  Future<void> _readTrigger() async {
    await runAction(context, () async {
      final t = await dc.bridge.offlineRecordingTriggerSetup(id!);
      setState(() {
        _trigger = t;
        _triggerMode = t.mode;
        _triggerTypes
          ..clear()
          ..addAll(t.features.keys);
        for (final e in t.features.entries) {
          if (e.value != null) _settings[e.key] = e.value!;
        }
      });
    });
  }

  Future<void> _writeTrigger() async {
    final i = id!;
    final features = <PolarDataType, SensorSetting?>{};
    for (final t in _triggerTypes) {
      if (t.needsSettings && _settings[t] == null) {
        final s = await pickSensorSettings(
          context,
          title: '${t.label} trigger settings',
          load: (full) => full
              ? dc.bridge.requestFullOfflineRecordingSettings(i, t)
              : dc.bridge.requestOfflineRecordingSettings(i, t),
        );
        if (s == null) return;
        _settings[t] = s;
      }
      features[t] = t.needsSettings ? _settings[t] : null;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => dc.bridge.setOfflineRecordingTrigger(
        i,
        OfflineRecordingTrigger(mode: _triggerMode, features: features),
        secretHex: _secretHex,
      ),
      success: 'Trigger set. Takes effect on next device start.',
    );
    if (ok) await _readTrigger();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: dc,
      builder: (context, _) {
        final ready = dc.featuresReady.contains(
          'FEATURE_POLAR_OFFLINE_RECORDING',
        );
        if (ready && _types == null && !_autoLoaded) {
          _autoLoaded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
        }
        final enabled = dc.isConnected && ready;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Section(
              title: 'Recording',
              trailing: IconButton(
                onPressed: enabled ? _refresh : null,
                icon: const Icon(Icons.refresh),
              ),
              children: [
                if (!enabled)
                  const Text('Offline recording feature not ready.'),
                Text(
                  'A type that is live-streaming cannot be recorded at the same '
                  'time (ERROR_ALREADY_IN_STATE). Stop the live stream first.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_recording.isNotEmpty)
                  Text(
                    'Currently recording: ${_recording.map((t) => t.label).join(', ')}',
                  ),
                for (final t in _types ?? const <PolarDataType>[])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.label),
                    subtitle: t.needsSettings && _settings[t] != null
                        ? Text(_settings[t].toString())
                        : null,
                    trailing: ButtonRow([
                      if (t.needsSettings)
                        IconButton(
                          icon: const Icon(Icons.tune),
                          onPressed: !enabled
                              ? null
                              : () async {
                                  final s = await pickSensorSettings(
                                    context,
                                    title: '${t.label} recording settings',
                                    initial: _settings[t],
                                    load: (full) => full
                                        ? dc.bridge
                                              .requestFullOfflineRecordingSettings(
                                                id!,
                                                t,
                                              )
                                        : dc.bridge
                                              .requestOfflineRecordingSettings(
                                                id!,
                                                t,
                                              ),
                                  );
                                  if (s != null) {
                                    setState(() => _settings[t] = s);
                                  }
                                },
                        ),
                      _recording.contains(t)
                          ? FilledButton.tonal(
                              onPressed: () => _stop(t),
                              child: const Text('Stop'),
                            )
                          : FilledButton(
                              onPressed: enabled ? () => _start(t) : null,
                              child: const Text('Record'),
                            ),
                    ]),
                  ),
                TextField(
                  controller: _secret,
                  decoration: const InputDecoration(
                    labelText: 'Encryption secret (optional, 32 hex chars)',
                    helperText: 'Used for start, trigger and fetch. Leave empty for plain recordings.',
                  ),
                ),
              ],
            ),
            Section(
              title: 'Automatic trigger',
              trailing: ButtonRow([
                TextButton(
                  onPressed: enabled ? _readTrigger : null,
                  child: const Text('Read'),
                ),
                FilledButton(
                  onPressed: enabled ? _writeTrigger : null,
                  child: const Text('Set'),
                ),
              ]),
              children: [
                if (_trigger != null)
                  Text(
                    'On device: ${_trigger!.mode.label}'
                    '${_trigger!.features.isEmpty ? '' : ' · ${_trigger!.features.keys.map((t) => t.label).join(', ')}'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                DropdownButtonFormField<TriggerMode>(
                  initialValue: _triggerMode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  items: [
                    for (final m in TriggerMode.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) =>
                      setState(() => _triggerMode = m ?? TriggerMode.disabled),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final t in _types ?? const <PolarDataType>[])
                      FilterChip(
                        label: Text(t.label),
                        selected: _triggerTypes.contains(t),
                        onSelected: (v) => setState(
                          () => v
                              ? _triggerTypes.add(t)
                              : _triggerTypes.remove(t),
                        ),
                      ),
                  ],
                ),
                const Text(
                  'PPI with "on exercise start" is not supported by the Verity Sense.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            Section(
              title: 'Recordings on device',
              trailing: FilledButton.tonal(
                onPressed: enabled && !_listing ? _list : null,
                child: Text(_listing ? 'Listing…' : 'List'),
              ),
              children: [
                if (_listing) const LinearProgressIndicator(),
                if (_entries != null && _entries!.isEmpty && !_listing)
                  const Text('No recordings.'),
                if (_entries == null)
                  const Text(
                    'Device must be in sensor mode (not recording internally) or the SDK returns SYSTEM_BUSY.',
                    style: TextStyle(fontSize: 12),
                  ),
                for (final e in _entries ?? const <OfflineRecordingEntry>[])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e.type.label} · ${formatBytes(e.size)}'),
                    subtitle: Text(
                      '${e.date}\n${e.path}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    isThreeLine: true,
                    trailing: ButtonRow([
                      IconButton(
                        icon: const Icon(Icons.download),
                        onPressed: () => _fetch(e),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(e),
                      ),
                    ]),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
