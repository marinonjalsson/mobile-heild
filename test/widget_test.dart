import 'package:flutter_test/flutter_test.dart';
import 'package:heild/main.dart';

void main() {
  testWidgets('scan page renders without a platform', (tester) async {
    await tester.pumpWidget(const HeildApp());
    await tester.pump();
    expect(find.text('heild'), findsOneWidget);
    expect(find.text('Scan'), findsWidgets);
  });
}
