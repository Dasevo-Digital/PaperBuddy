import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Darstellung umschalten und merken', (tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(NavigationBar))).brightness;
    expect(brightness(), Brightness.light, reason: 'Testumgebung ist hell');

    await tester.tap(find.text('Einstellungen').last);
    await settle(tester);
    await tester.tap(find.text('Dunkel'));
    await settle(tester);
    expect(brightness(), Brightness.dark);
    expect(state.store.themeMode, 'dark');

    // Neuer Start liest die Einstellung wieder.
    final restarted = AppState(state.store, httpClient: server.client);
    expect(restarted.themeMode.value, ThemeMode.dark);
    state.notifications.stop();
  });
}
