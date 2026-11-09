import 'package:flutter/material.dart';

import '../main.dart';
import 'settings/settings_page.dart';
import 'viewer/dashboard_page.dart';
import 'viewer/graphs_page.dart';
import 'viewer/table_page.dart';

/// Bottom navigation: the data viewer first, the device under Settings.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appController,
      builder: (context, _) {
        if (!appController.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          body: IndexedStack(
            index: _index,
            children: const [
              DashboardPage(),
              GraphsPage(),
              TablePage(),
              SettingsPage(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.favorite_outline),
                selectedIcon: Icon(Icons.favorite),
                label: 'Dashboard',
              ),
              NavigationDestination(
                icon: Icon(Icons.show_chart),
                label: 'Graphs',
              ),
              NavigationDestination(
                icon: Icon(Icons.table_rows_outlined),
                selectedIcon: Icon(Icons.table_rows),
                label: 'Table',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    );
  }
}
