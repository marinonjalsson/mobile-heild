import 'dart:async';

import 'package:flutter/material.dart';

import 'polar/polar_bridge.dart';
import 'state/app_controller.dart';
import 'state/device_controller.dart';
import 'ui/home_page.dart';

/// The single device controller for the app. Plain global: the app works with
/// one Polar device at a time.
final deviceController = DeviceController(PolarBridge.instance);

/// Database, settings and sync. Initialised before the first frame.
final appController = AppController(deviceController);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The engine may start headless (foreground service woke the process).
  // init() connects and syncs on its own; the UI attaches when the Activity
  // appears and reads the same controllers.
  unawaited(appController.init());
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
      home: const HomePage(),
    );
  }
}
