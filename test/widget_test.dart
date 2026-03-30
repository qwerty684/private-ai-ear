import 'package:aihelper/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('assistant shell renders', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const AiHelperApp());

    expect(find.text('Mini call mode'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Listen again'), findsOneWidget);
  });
}
