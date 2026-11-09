import 'package:flutter/material.dart';

import 'polar/polar_bridge.dart';
import 'state/device_controller.dart';
import 'ui/scan_page.dart';

/// The single device controller for the app. Plain global: the app works with
/// one Polar device at a time and has no other shared state yet.
final deviceController = DeviceController(PolarBridge.instance);

void main() {
  runApp(const HeildApp());
}

class HeildApp extends StatelessWidget {
  const HeildApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'heild',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFD32F2F),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFFD32F2F),
        brightness: Brightness.dark,
      ),
      home: const ScanPage(),
    );
  }
}
