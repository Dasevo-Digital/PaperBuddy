import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/format.dart';
import 'package:paperbuddy/src/l10n.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting());
  setUp(() async => server = await TestServer.start());
  tearDown(() async {
    await server.stop();
    useLanguage('de');
  });

  testWidgets('Englische Oberfläche und Wechsel auf Deutsch', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.setLanguage('en');
      await s.restore();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    expect(find.text('Server address'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(formatDay(DateTime(2026, 10, 9)), 'Oct 9, 2026');

    // Meldungen des API-Clients kommen ebenfalls auf Englisch.
    await tester.enterText(find.widgetWithText(TextFormField, 'Server address'), TestServer.address);
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), TestServer.username);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'falsch');
    await tester.runAsync(() async {
      await tester.tap(find.text('Sign in'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await settle(tester);
    expect(find.text('Wrong username or password.'), findsOneWidget);

    await tester.runAsync(() => state.login(TestServer.address, TestServer.username, TestServer.password));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Documents'), findsWidgets);
    await tester.tap(find.text('Settings').last);
    await settle(tester);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);

    await tester.tap(find.text('Deutsch'));
    await settle(tester);
    expect(state.language.value, 'de');
    expect(appLanguage, 'de');
    expect(find.text('Einstellungen'), findsWidgets);
    expect(find.text('Sprache'), findsOneWidget);
    expect(formatDay(DateTime(2026, 10, 9)), '9. Okt. 2026');
  });

  test('System folgt dem Gerät, sonst Englisch', () {
    deviceLanguage = () => 'fr';
    expect(resolveLanguage('system'), 'en');
    deviceLanguage = () => 'de';
    expect(resolveLanguage(null), 'de');
    expect(resolveLanguage('en'), 'en');
  });
}
