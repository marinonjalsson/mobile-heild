import 'package:flutter/material.dart';

import '../main.dart';
import '../state/device_controller.dart';
import 'advanced/advanced_tab.dart';
import 'device/device_tab.dart';
import 'live/live_tab.dart';
import 'offline/offline_tab.dart';
import 'widgets/common.dart';

/// The connected device: four tabs covering every SDK capability of the Verity Sense.
class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: deviceController,
      builder: (context, _) {
        final dc = deviceController;
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: AppBar(
              title: Text(dc.device?.name ?? dc.deviceId ?? 'Device'),
              actions: [
                if (dc.batteryLevel != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: Text(
                        '${dc.batteryLevel}%${dc.chargeState == 'CHARGING' ? ' ⚡' : ''}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: dc.isConnected ? 'Disconnect' : 'Reconnect',
                  icon: Icon(
                    dc.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_searching,
                  ),
                  onPressed: () => runAction(
                    context,
                    () => dc.isConnected
                        ? dc.disconnect()
                        : dc.connect(dc.deviceId!),
                  ),
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(78),
                child: Column(
                  children: [
                    _StatusBar(dc),
                    const TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: 'Live'),
                        Tab(text: 'Offline'),
                        Tab(text: 'Device'),
                        Tab(text: 'Advanced'),
                        Tab(text: 'Log'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            body: const TabBarView(
              children: [
                LiveTab(),
                OfflineTab(),
                DeviceTab(),
                AdvancedTab(),
                _LogTab(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar(this.dc);
  final DeviceController dc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (dc.connection) {
      PolarConnectionState.connected => ('Connected', scheme.primary),
      PolarConnectionState.connecting => ('Connecting…', scheme.tertiary),
      PolarConnectionState.disconnected => (
        'Disconnected${dc.lastDisconnect == null ? '' : ' · ${dc.lastDisconnect!.reason}'}',
        scheme.error,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (dc.firmwareVersion != null) Text('FW ${dc.firmwareVersion}'),
        ],
      ),
    );
  }
}

class _LogTab extends StatelessWidget {
  const _LogTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: deviceController,
      builder: (context, _) => ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: deviceController.eventLog.length,
        itemBuilder: (context, i) => SelectableText(
          deviceController.eventLog[i],
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}
