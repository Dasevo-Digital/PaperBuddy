import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting());
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Integrations-Token anlegen, Schlüssel sehen, löschen', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, TestServer.username, TestServer.password);
      await s.client.createTag('Familie');
      await s.refreshLabels();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    await tester.tap(find.text('Einstellungen').last);
    await settle(tester);
    await tester.tap(find.text('Zugriff für andere Apps'));
    await settle(tester);
    expect(find.text('Noch keine Token.'), findsOneWidget);

    await tester.tap(find.text('Token anlegen'));
    await settle(tester);
    // Name „Famio“ und Tag „Familie“ sind vorbelegt.
    expect(find.text('Famio'), findsOneWidget);
    expect(find.text('Familie'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Token anlegen'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Token angelegt'), findsOneWidget);
    final key = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(key, startsWith('pbi_'));
    await tester.tap(find.text('Fertig'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Famio'), findsOneWidget);
    expect(find.textContaining('Tag: Familie · Noch nicht benutzt'), findsOneWidget);

    await tester.tap(find.byTooltip('Löschen'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Noch keine Token.'), findsOneWidget);
  });
}
