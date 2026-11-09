import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heild/ui/scan_page.dart';

void main() {
  testWidgets('scan page renders without a platform', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ScanPage()));
    await tester.pump();
    expect(find.text('Sensors'), findsOneWidget);
    expect(find.text('Scan'), findsWidgets);
  });
}
