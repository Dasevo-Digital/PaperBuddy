// Hochladen mit Metadaten (Korrespondent und Tag neu angelegt),
// Volltextsuche, Detailansicht und Frist – über die Oberfläche, geprüft auch
// auf dem Server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/file_intake.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Hochladen mit Metadaten, Volltextsuche und Frist', skip: skipWithoutServer, timeout: const Timeout(Duration(minutes: 3)), (tester) async {
    // Ein zweites Dokument, damit die Suche etwas auszusortieren hat.
    final server = await PaperlessClient.login(e2eServer, e2eUser, e2ePassword);
    addTearDown(server.close);
    await server.waitForTask(
      await server.uploadDocument(utf8.encode('Gasrechnung Abschlag Oktober'), 'gas.txt', title: 'Gasrechnung'),
      interval: const Duration(milliseconds: 200),
    );

    final state = await freshState();
    await state.restore();
    await state.login(e2eServer, e2eUser, e2ePassword);
    await desktopWindow(tester);
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await pumpUntil(tester, () => shows('Gasrechnung'), reason: 'Dokumentliste');

    // Wie beim Ablegen auf das Fenster: eine Datei zum Hochladen anbieten.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    offerFiles(state, navigator, [
      (
        name: 'strom.txt',
        bytes: Uint8List.fromList(utf8.encode('Jahresabrechnung Strom, Zählernummer 4711, Stadtwerke Musterstadt')),
      ),
    ]).ignore();
    await pumpUntil(tester, () => shows('Datei hochladen'), reason: 'Upload-Formular');
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Stromrechnung 2026');

    // Korrespondent direkt im Formular anlegen.
    await tester.tap(find.ancestor(of: find.text('Korrespondent'), matching: find.byType(InkWell)).first);
    await pumpUntil(tester, () => shows('Suchen oder neu anlegen'), reason: 'Auswahl Korrespondent');
    await tester.enterText(find.widgetWithText(TextField, 'Suchen oder neu anlegen'), 'Stadtwerke Musterstadt');
    await tester.pump();
    await tester.tap(find.text('„Stadtwerke Musterstadt“ anlegen'));
    // Das Feld zeigt den Namen, nicht die Nummer des neuen Eintrags.
    await pumpUntil(
      tester,
      () => !shows('Suchen oder neu anlegen') && shows('Stadtwerke Musterstadt'),
      reason: 'Korrespondent übernommen',
    );

    // Tag anlegen und übernehmen.
    await tester.tap(find.text('Auswählen'));
    await pumpUntil(tester, () => shows('Suchen oder neu anlegen'), reason: 'Auswahl Tags');
    await tester.enterText(find.widgetWithText(TextField, 'Suchen oder neu anlegen'), 'Haus');
    await tester.pump();
    await tester.tap(find.text('„Haus“ anlegen'));
    await pumpUntil(tester, () => shows('Haus'), reason: 'Tag angelegt');
    await tester.tap(find.text('Übernehmen'));
    await pumpUntil(tester, () => !shows('Übernehmen'), reason: 'Tags übernommen');

    await tester.tap(find.text('Hochladen'));
    await pumpUntil(
      tester,
      () => shows('Stromrechnung 2026') && shows('2 Dokumente'),
      reason: 'neues Dokument in der Liste',
    );

    // Volltextsuche nach einem Wort aus dem Inhalt.
    await tester.enterText(find.byType(SearchBar), 'Zählernummer');
    await pumpUntil(tester, () => shows('1 Dokument'), reason: 'Suchtreffer');
    expect(find.text('Stromrechnung 2026'), findsOneWidget);
    expect(find.text('Gasrechnung'), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'Wasserrechnung');
    await pumpUntil(tester, () => shows('Keine passenden Dokumente gefunden.'), reason: 'keine Treffer');
    await tester.enterText(find.byType(SearchBar), 'Zählernummer');
    await pumpUntil(tester, () => shows('Stromrechnung 2026'), reason: 'wieder gefunden');

    // Detailansicht mit den Metadaten, dann eine Frist anlegen.
    await tester.tap(find.text('Stromrechnung 2026'));
    await pumpUntil(tester, () => shows('Frist hinzufügen'), reason: 'Detailansicht');
    expect(find.text('Stadtwerke Musterstadt'), findsWidgets);
    expect(find.text('Haus'), findsWidgets);
    await reveal(tester, find.text('Frist hinzufügen'));
    await tester.tap(find.text('Frist hinzufügen'));
    await pumpUntil(tester, () => shows('Fällig am'), reason: 'Frist-Dialog');
    await tester.enterText(find.widgetWithText(TextField, 'Notiz'), 'Abschlag prüfen');
    await tester.tap(find.text('Hinzufügen'));
    await pumpUntil(tester, () => shows('Abschlag prüfen'), reason: 'Frist in der Detailansicht');

    // Und so ist es auf dem Server angekommen.
    final found = await server.documents(filter: const DocumentFilter(query: 'Zählernummer'));
    expect(found.results.map((d) => d.title), ['Stromrechnung 2026']);
    final doc = found.results.single;
    final correspondents = await server.correspondents();
    expect(correspondents.firstWhere((c) => c.id == doc.correspondent).name, 'Stadtwerke Musterstadt');
    final tags = await server.tags();
    expect([for (final id in doc.tags) tags.firstWhere((t) => t.id == id).name], ['Haus']);
    final reminders = await server.reminders(document: doc.id);
    expect(reminders.single.note, 'Abschlag prüfen');
    expect(reminders.single.done, isFalse);
  });
}
