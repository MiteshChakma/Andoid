import 'package:flutter_test/flutter_test.dart';

import 'package:delivery_route_tracker/main.dart';

void main() {
  testWidgets('shows tracker home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const DeliveryTrackerApp());

    expect(find.text('Tracker'), findsWidgets);
    expect(find.text('Ready to track'), findsOneWidget);
  });
}
