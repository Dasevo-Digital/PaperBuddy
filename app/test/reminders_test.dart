import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/notifications.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Fristen: anlegen, fällig in Übersicht und Glocke, abhaken', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late int docId;
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      final f = File('${server.dir.path}/vertrag.txt')
        ..writeAsStringSync('Mietvertrag Wohnung');
      await server.server.consumer.waitFor(
        await server.server.consumer.submit(f, originalName: 'vertrag.txt'),
      );
      docId = (await s.client.documents()).results.single.id;
      // Heute fällig: erscheint sofort in Glocke und Übersicht.
      await s.client.createReminder(
        docId,
        DateTime.now(),
        note: 'Zählerstand melden',
      );
      await s.notifications.refresh();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester, const Duration(milliseconds: 600));

    // Glocke zählt die fällige Frist (dazu der Import des Dokuments).
    expect(find.text('2'), findsWidgets);
    expect(
      state.notifications.notices.where((n) => n.kind == NoticeKind.reminder),
      hasLength(1),
    );

    // In der Detailansicht eine weitere Frist anlegen.
    await tester.tap(find.text('vertrag'));
    await settle(tester, const Duration(milliseconds: 500));
    expect(find.text('Zählerstand melden'), findsOneWidget);
    await tester.tap(find.text('Frist hinzufügen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Notiz'),
      'Kündigungsfrist',
    );
    await tester.tap(find.text('Hinzufügen'));
    await settle(tester, const Duration(milliseconds: 500));
    expect(find.text('Kündigungsfrist'), findsOneWidget);

    // Fällige Frist abhaken.
    await tester.tap(
      find.widgetWithText(CheckboxListTile, 'Zählerstand melden'),
    );
    await settle(tester, const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      final open = await state.client.reminders(done: false);
      expect(open.map((r) => r.note), ['Kündigungsfrist']);
    });

    // Übersicht: nur noch die offene Frist (in einer Woche).
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    await tester.tap(find.text('Übersicht'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Fristen'), findsOneWidget);
    expect(find.text('Kündigungsfrist'), findsOneWidget);
    expect(find.text('Zählerstand melden'), findsNothing);
    state.notifications.stop();
  });
}
