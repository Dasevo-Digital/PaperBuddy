import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Suchvorschläge vervollständigen das letzte Wort', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      for (final (name, text) in [
        ('strom', 'Stromrechnung der Stadtwerke'),
        ('miete', 'Mietvertrag Wohnung'),
      ]) {
        final f = File('${server.dir.path}/$name.txt')..writeAsStringSync(text);
        await server.server.consumer.waitFor(
          await server.server.consumer.submit(f, originalName: '$name.txt'),
        );
      }
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    expect(find.text('2 Dokumente'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar).first, 'stro');
    await settle(tester, const Duration(milliseconds: 700));
    expect(find.widgetWithText(ActionChip, 'stromrechnung'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, 'stromrechnung'));
    await settle(tester, const Duration(milliseconds: 500));
    expect(find.text('stromrechnung '), findsOneWidget, reason: 'im Suchfeld');
    expect(find.text('1 Dokument'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'stromrechnung'), findsNothing);
    state.notifications.stop();
  });
}
