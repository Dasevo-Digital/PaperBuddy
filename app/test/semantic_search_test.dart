import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

/// Wartet in echter Zeit, bis [finder] etwas findet. Anders als
/// `pumpAndSettle` spult das die Testzeit nicht vor: Solange ein Ladekreis
/// läuft, liefe sonst die 30-Sekunden-Grenze des Clients ab, bevor der
/// Server (auf einem langsamen CI-Rechner) geantwortet hat.
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) fail('Nicht erschienen: $finder');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting());
  tearDown(() => server.stop());

  Future<void> start(WidgetTester tester, {required bool ai}) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = (await tester.runAsync(() => TestServer.start(ai: ai)))!;
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, TestServer.username, TestServer.password);
      for (final (name, text) in [
        ('Stromrechnung', 'Stadtwerke Jahresabrechnung Strom Verbrauch Abschlag Nachzahlung'),
        ('Stromabschlag', 'Stadtwerke Jahresabrechnung Strom Verbrauch Abschlag Guthaben'),
        ('Laborbefund', 'Praxis Befundbericht Blutwerte Labor Kontrolle'),
      ]) {
        final file = File('${server.dir.path}/$name.txt')..writeAsStringSync(text);
        await server.server.consumer.waitFor(await server.server.consumer.submit(file, originalName: '$name.txt'));
      }
      await s.refreshLabels();
      await s.refreshAi();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
  }

  testWidgets('Suche nach Bedeutung umschalten', (tester) async {
    await start(tester, ai: true);
    expect(find.text('3 Dokumente'), findsOneWidget);
    await tester.tap(find.byTooltip('Nach Bedeutung suchen'));
    await settle(tester);
    expect(find.byTooltip('Nach Wörtern suchen'), findsOneWidget);
    // Kein Wort „Blutuntersuchung“ im Text, aber Wörter des Befunds.
    await tester.enterText(find.byType(SearchBar).first, 'Blutwerte Labor');
    await tester.pump(const Duration(milliseconds: 400)); // Suche abschicken
    await waitFor(tester, find.text('1 Dokument'));
    expect(find.text('Laborbefund'), findsOneWidget);
    expect(find.text('Stromrechnung'), findsNothing);
    expect(find.text('1 Dokument'), findsOneWidget);
    // Der Server stellt nach der Anfrage den Zeitgeber, der das Modell nach
    // der Ruhezeit freigibt; in Testzeit ablaufen lassen.
    await tester.pump(const Duration(minutes: 3));
  });

  testWidgets('Ohne lokale KI kein Umschalter, ähnliche Dokumente trotzdem', (tester) async {
    await start(tester, ai: false);
    expect(find.byTooltip('Nach Bedeutung suchen'), findsNothing);
    await tester.tap(find.text('Stromrechnung'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Ähnliche Dokumente'), 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Ähnliche Dokumente'));
    await waitFor(tester, find.text('Stromabschlag'));
    expect(find.text('Laborbefund'), findsNothing);
  });
}
