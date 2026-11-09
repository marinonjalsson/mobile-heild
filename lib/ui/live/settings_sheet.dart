import 'package:flutter/material.dart';

import '../../polar/models.dart';
import '../../polar/polar_errors.dart';

/// Lets the user pick one value per setting type for a stream or recording.
///
/// [load] fetches the available options; `full == true` asks for the device's
/// complete capabilities (SDK mode) instead of what the current mode allows.
Future<SensorSetting?> pickSensorSettings(
  BuildContext context, {
  required String title,
  required Future<SensorSettingOptions> Function(bool full) load,
  SensorSetting? initial,
}) {
  return showModalBottomSheet<SensorSetting>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) =>
        _SettingsSheet(title: title, load: load, initial: initial),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.title, required this.load, this.initial});

  final String title;
  final Future<SensorSettingOptions> Function(bool full) load;
  final SensorSetting? initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _full = false;
  SensorSettingOptions? _options;
  SensorSetting? _selected;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final o = await widget.load(_full);
      var sel = o.defaults();
      // Keep previously chosen values when still offered.
      final prev = _selected ?? widget.initial;
      if (prev != null) {
        for (final e in prev.values.entries) {
          if (o.options[e.key]?.contains(e.value) ?? false)
            sel = sel.copyWith(e.key, e.value);
        }
      }
      setState(() {
        _options = o;
        _selected = sel;
        _loading = false;
      });
    } on PolarException catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Full capabilities (SDK mode)'),
            subtitle: const Text(
              'Show every rate/range the device supports, not only the current mode',
            ),
            value: _full,
            onChanged: (v) {
              setState(() => _full = v);
              _reload();
            },
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (o != null && !_loading && o.isEmpty)
            const Text('No settings available in the current state.'),
          if (o != null && !_loading)
            for (final e in o.options.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: DropdownButtonFormField<int>(
                  decoration: InputDecoration(
                    labelText: e.key.label,
                    border: const OutlineInputBorder(),
                  ),
                  initialValue: _selected?.values[e.key],
                  items: [
                    for (final v in e.value)
                      DropdownMenuItem(
                        value: v,
                        child: Text('$v ${e.key.unit}'.trim()),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null)
                      setState(() => _selected = _selected!.copyWith(e.key, v));
                  },
                ),
              ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _selected == null
                ? null
                : () => Navigator.pop(context, _selected),
            child: const Text('Use these settings'),
          ),
        ],
      ),
    );
  }
}
