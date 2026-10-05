import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperbuddy/src/widgets/text_menus.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          return switch (call.method) {
            'Clipboard.getData' => {'text': 'geheim-123'},
            'Clipboard.hasStrings' => {'value': true},
            _ => null,
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<TextEditingController> pumpField(WidgetTester tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: TextField(
                controller: controller,
                obscureText: true,
                contextMenuBuilder: passwordContextMenu,
              ),
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('Rechtsklick setzt in ein Passwortfeld ein', (tester) async {
    final controller = await pumpField(tester);
    await tester.tapAt(
      tester.getCenter(find.byType(TextField)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Einsetzen'), findsOneWidget);
    expect(find.text('Kopieren'), findsNothing);

    await tester.tap(find.text('Einsetzen'));
    await tester.pumpAndSettle();
    expect(controller.text, 'geheim-123');
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Langes Drücken setzt in ein Passwortfeld ein', (tester) async {
    final controller = await pumpField(tester);
    await tester.longPress(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einsetzen'));
    await tester.pumpAndSettle();
    expect(controller.text, 'geheim-123');
  }, variant: TargetPlatformVariant.mobile());
}
