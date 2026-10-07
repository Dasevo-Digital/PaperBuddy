import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/notifications.dart';
import 'package:paperbuddy/src/upload_queue.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  test('Upload und Server-Import erscheinen, Entfernen quittiert den Task', () async {
    final state = await newAppState(server);
    await state.login(TestServer.address, TestServer.username, TestServer.password);
    final center = state.notifications;
    final popups = <Notice>[];
    center.onPopup = popups.add;

    await state.uploads.add(state.client, [
      UploadRequest('rechnung.txt', text('Rechnung Handwerker 03.03.2026')),
    ]);
    expect(center.notices.single.kind, NoticeKind.success);
    expect(center.notices.single.documentId, isNotNull);
    expect(popups, hasLength(1), reason: 'genau ein kurzer Hinweis');

    // Abfrage beim Server bringt denselben Task nicht doppelt.
    await center.refresh();
    expect(center.notices, hasLength(1));
    expect(popups, hasLength(1));

    // Import über den Eingangsordner des Servers (nicht aus der App).
    var changed = 0;
    state.documentsChanged.addListener(() => changed++);
    final file = File('${server.dir.path}/scan.txt')..writeAsStringSync('Kontoauszug September 2026');
    await server.server.consumer.waitFor(await server.server.consumer.submit(file, originalName: 'scan.txt'));
    await center.refresh();
    expect(center.notices.map((n) => n.title), containsAll(['rechnung.txt', 'scan.txt']));
    expect(popups.map((n) => n.title), contains('scan.txt'));
    await Future<void>.delayed(
      AppState.arrivalDelay + const Duration(milliseconds: 200),
    );
    expect(changed, greaterThan(0), reason: 'Listen laden neu');

    await center.clearFinished();
    expect(center.notices, isEmpty);
    final open = server.server.db.select('SELECT COUNT(*) AS n FROM tasks WHERE acknowledged = 0').first['n'];
    expect(open, 0, reason: 'auf dem Server als gelesen markiert');
    await center.refresh();
    expect(center.notices, isEmpty);
    center.stop();
  });

  testWidgets('Glocke zeigt ungelesene Meldungen, Übersicht zeigt Statistik', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, TestServer.username, TestServer.password);
      await s.client.createTag('Posteingang', isInboxTag: true);
      await s.uploads.add(s.client, [
        UploadRequest('brief.txt', text('Brief vom Finanzamt 01.09.2026')),
        UploadRequest('notiz.txt', text('Kurze Notiz zum Vertrag')),
      ]);
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    // Zwei neue Ergebnisse, Glocke mit Zähler.
    expect(find.text('2'), findsWidgets);
    await tester.tap(find.byTooltip('Benachrichtigungen').first);
    await settle(tester);
    expect(find.text('brief.txt'), findsOneWidget);
    expect(find.text('Alle entfernen'), findsOneWidget);
    await tester.tap(find.text('Alle entfernen'));
    await settle(tester);
    expect(find.text('Keine Benachrichtigungen'), findsOneWidget);
    await tester.tapAt(const Offset(5, 995));
    await settle(tester);

    await tester.tap(find.text('Übersicht'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Statistiken'), findsOneWidget);
    expect(find.text('Dokumente insgesamt:'), findsOneWidget);
    expect(find.text('Dokumente im Posteingang:'), findsOneWidget);
    expect(find.textContaining('TXT'), findsWidgets);
    expect(find.textContaining('100,0%'), findsOneWidget);
    state.notifications.stop();
  });
}
