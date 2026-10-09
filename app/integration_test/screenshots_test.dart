// Screenshots für das README: die echte App mit ausgedachten
// Demo-Dokumenten gegen einen frischen Server. Läuft nur mit
// PAPERBUDDY_SHOTS, gestartet von
//
//   tool/screenshots.sh            (Server im Container, setzt die PNGs zusammen)
//
// Die macOS-Test-App läuft in der Sandbox, ihr Container ist für andere
// Programme geschlossen. Darum gehen die Bilder als Base64 in Zeilen
// „SHOT <name> <stück>“ hinaus, die das Skript wieder zusammensetzt.
// Sitzung und Einstellungen bleiben im Arbeitsspeicher, der Zwischenspeicher
// in einem Temp-Ordner.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/file_cache.dart';
import 'package:paperbuddy/src/session_store.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

const _shots = String.fromEnvironment('PAPERBUDDY_SHOTS');
const _server = String.fromEnvironment(
  'PAPERBUDDY_SHOTS_SERVER',
  defaultValue: 'http://127.0.0.1:18090',
);
const _user = 'demo';
const _password = String.fromEnvironment('PAPERBUDDY_SHOTS_PASSWORD');

/// Ein ausgedachter Brief: Absender, Betreff, Text und Zuordnung.
class _Letter {
  const _Letter(
    this.title,
    this.sender,
    this.type,
    this.tags,
    this.created,
    this.lines, {
    this.amount,
    this.reminder,
  });

  final String title;
  final String sender;
  final String type;
  final List<String> tags;
  final DateTime created;
  final List<String> lines;
  final String? amount;

  /// Frist in Tagen ab heute und Notiz.
  final (int, String)? reminder;
}

final _letters = [
  _Letter(
    'Stromrechnung 2026',
    'Stadtwerke Musterstadt',
    'Rechnung',
    ['Haus', 'Steuer 2026'],
    DateTime(2026, 9, 15),
    [
      'Jahresabrechnung Strom für den Zeitraum 01.09.2025 bis 31.08.2026.',
      'Verbrauch: 2.418 kWh, Zählernummer 1ESY1160-4471.',
      'Der Abschlag ab Oktober beträgt 68,00 EUR monatlich.',
    ],
    amount: '142,37 EUR',
  ),
  _Letter(
    'Mietvertrag Wohnung Lindenhof',
    'Hausverwaltung Lindenhof',
    'Vertrag',
    ['Haus', 'Wichtig'],
    DateTime(2025, 3, 1),
    [
      'Mietvertrag über die Wohnung im 2. Obergeschoss links, 3 Zimmer, 78 m².',
      'Mietbeginn: 01.04.2025. Kaltmiete 820,00 EUR, Nebenkosten 190,00 EUR.',
      'Die Kündigungsfrist beträgt drei Monate zum Monatsende.',
    ],
    reminder: (11, 'Nebenkostenabrechnung prüfen'),
  ),
  _Letter(
    'Kfz-Versicherung Beitragsrechnung',
    'Nordstern Versicherung',
    'Rechnung',
    ['Auto'],
    DateTime(2026, 8, 20),
    [
      'Beitragsrechnung für Ihre Kfz-Haftpflicht- und Teilkaskoversicherung.',
      'Fahrzeug: Kennzeichen MS-AB 123, Schadenfreiheitsklasse SF 12.',
      'Versicherungszeitraum 01.01.2027 bis 31.12.2027.',
    ],
    amount: '486,20 EUR',
    reminder: (52, 'Wechselfrist Kfz-Versicherung'),
  ),
  _Letter(
    'Rechnung Zahnreinigung',
    'Praxis Dr. Sommer',
    'Rechnung',
    ['Gesundheit', 'Steuer 2026'],
    DateTime(2026, 7, 2),
    [
      'Professionelle Zahnreinigung am 24.06.2026.',
      'Bitte überweisen Sie den Betrag innerhalb von 14 Tagen.',
    ],
    amount: '96,50 EUR',
  ),
  _Letter(
    'Einkommensteuerbescheid 2025',
    'Finanzamt Musterstadt',
    'Bescheid',
    ['Steuer 2026', 'Wichtig'],
    DateTime(2026, 6, 11),
    [
      'Bescheid für 2025 über Einkommensteuer und Solidaritätszuschlag.',
      'Die festgesetzte Steuer ist niedriger als die Vorauszahlungen.',
      'Der Erstattungsbetrag wird auf Ihr Konto überwiesen.',
    ],
    amount: '612,00 EUR Erstattung',
  ),
  _Letter(
    'Handwerkerrechnung Badezimmer',
    'Elektro Becker GmbH',
    'Rechnung',
    ['Haus', 'Steuer 2026'],
    DateTime(2026, 5, 18),
    [
      'Austausch der Beleuchtung und zweier Steckdosen im Badezimmer.',
      'Arbeitszeit 3,5 Stunden, Material laut Aufstellung.',
      'Lohnkosten nach § 35a EStG: 245,00 EUR.',
    ],
    amount: '389,90 EUR',
  ),
  _Letter(
    'Mobilfunkvertrag',
    'Funkwerk Mobil',
    'Vertrag',
    ['Wichtig'],
    DateTime(2026, 1, 10),
    [
      'Auftragsbestätigung für Ihren Tarif Funkwerk Allnet 20 GB.',
      'Mindestvertragslaufzeit 24 Monate, monatlich 14,99 EUR.',
    ],
    reminder: (83, 'Mindestlaufzeit endet – Tarif vergleichen'),
  ),
  _Letter(
    'Kontoauszug September',
    'Bank am Markt',
    'Kontoauszug',
    ['Posteingang'],
    DateTime(2026, 9, 30),
    [
      'Kontoauszug Nr. 9/2026 für das Girokonto.',
      'Alter Kontostand 2.104,18 EUR, neuer Kontostand 2.356,40 EUR.',
    ],
  ),
  _Letter(
    'Wartung der Heizung',
    'Schornsteinfeger Klein',
    'Brief',
    ['Haus', 'Posteingang'],
    DateTime(2026, 10, 5),
    [
      'Die jährliche Feuerstättenschau steht an.',
      'Bitte bestätigen Sie uns einen der vorgeschlagenen Termine.',
    ],
    reminder: (5, 'Termin bestätigen'),
  ),
  _Letter(
    'Prüfbericht Hauptuntersuchung',
    'Prüfstelle Süd',
    'Bescheid',
    ['Auto'],
    DateTime(2026, 4, 22),
    [
      'Hauptuntersuchung nach § 29 StVZO ohne festgestellte Mängel.',
      'Nächste Hauptuntersuchung: 04/2028.',
    ],
  ),
];

const _tagColors = {
  'Haus': '#2f9e44',
  'Auto': '#1971c2',
  'Steuer 2026': '#f08c00',
  'Gesundheit': '#c2255c',
  'Wichtig': '#e03131',
  'Posteingang': '#7048e8',
};

String _day(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

Future<Uint8List> _pdf(_Letter l) async {
  final doc = pw.Document();
  final accent = PdfColor.fromHex(switch (l.type) {
    'Rechnung' => '#1c7ed6',
    'Vertrag' => '#2b8a3e',
    'Bescheid' => '#495057',
    'Kontoauszug' => '#0b7285',
    _ => '#862e9c',
  });
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 48, 56, 48),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                l.sender,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: accent,
                ),
              ),
              pw.Container(width: 36, height: 36, color: accent),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Hauptstraße 12 · 12345 Musterstadt',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 40),
          pw.Text('Alex Beispiel'),
          pw.Text('Musterweg 7'),
          pw.Text('12345 Musterstadt'),
          pw.SizedBox(height: 32),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Musterstadt, ${_day(l.created)}'),
          ),
          pw.SizedBox(height: 24),
          pw.Text(
            l.title,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),
          pw.Text('Sehr geehrte Damen und Herren,'),
          pw.SizedBox(height: 10),
          for (final line in l.lines)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Text(line),
            ),
          if (l.amount != null) ...[
            pw.SizedBox(height: 12),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              color: PdfColors.grey200,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Betrag'),
                  pw.Text(
                    l.amount!,
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
          pw.SizedBox(height: 24),
          pw.Text('Mit freundlichen Grüßen'),
          pw.SizedBox(height: 6),
          pw.Text(l.sender),
          pw.Spacer(),
          pw.Divider(color: PdfColors.grey400),
          pw.Text(
            'Musterbank · IBAN DE00 0000 0000 0000 0000 00 · ausgedachtes Beispiel',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Legt Tags, Korrespondenten, Typen, Dokumente, Fristen und eine
/// gespeicherte Ansicht an und wartet, bis der Server alles verarbeitet hat.
Future<void> _seed(PaperlessClient c) async {
  final tags = {
    for (final MapEntry(key: name, value: color) in _tagColors.entries)
      name: (await c.createTag(
        name,
        color: color,
        isInboxTag: name == 'Posteingang',
      )).id,
  };
  final senders = <String, int>{};
  final types = <String, int>{};
  final ids = <String, int>{};
  for (final l in _letters) {
    final sender = senders[l.sender] ??= (await c.createCorrespondent(
      l.sender,
    )).id;
    final type = types[l.type] ??= (await c.createDocumentType(l.type)).id;
    final task = await c.waitForTask(
      await c.uploadDocument(
        await _pdf(l),
        '${l.title}.pdf',
        title: l.title,
        created: l.created,
        correspondent: sender,
        documentType: type,
        tags: [for (final t in l.tags) tags[t]!],
      ),
      interval: const Duration(milliseconds: 300),
    );
    expect(task.status, TaskStatus.success, reason: task.result);
    ids[l.title] = task.documentId!;
    // Die lernende Zuordnung rät bei zehn Dokumenten wild, und der
    // Posteingangs-Tag kommt an jedes neue Dokument: Tags genau setzen.
    await c.updateDocument(task.documentId!, {
      'tags': [for (final t in l.tags) tags[t]!],
    });
  }
  final today = DateUtils.dateOnly(DateTime.now());
  for (final l in _letters) {
    final r = l.reminder;
    if (r == null) continue;
    await c.createReminder(
      ids[l.title]!,
      today.add(Duration(days: r.$1)),
      note: r.$2,
    );
  }
  await c.createSavedView(
    'Steuer 2026',
    DocumentFilter(tagsAll: {tags['Steuer 2026']!}),
    showOnDashboard: true,
  );
  await c.addNote(
    ids['Mietvertrag Wohnung Lindenhof']!,
    'Übergabeprotokoll liegt im Ordner „Wohnung“.',
  );
  // Ohne offene Meldungen in der Benachrichtigungszentrale.
  final done = await c.tasks();
  await c.acknowledgeTasks([
    for (final t in done)
      if (t.id != null) t.id!,
  ]);
}

/// Wartet in echter Zeit und zeichnet dabei weiter.
Future<void> _wait(WidgetTester tester, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README-Screenshots', skip: _shots.isEmpty, (tester) async {
    expect(_password, isNotEmpty, reason: 'PAPERBUDDY_SHOTS_PASSWORD fehlt');
    await initializeDateFormatting('de');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    FileCache.testBase = await Directory.systemTemp.createTemp('paperbuddy-shots-');

    final seeder = await PaperlessClient.login(_server, _user, _password);
    await _seed(seeder);
    seeder.close();

    final state = AppState(SessionStore(await SharedPreferences.getInstance()));
    await state.restore();
    await state.login(_server, _user, _password);

    final boundary = GlobalKey();
    Future<void> shot(String name) async {
      await _wait(tester, 2500);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final text = base64.encode(data!.buffer.asUint8List());
      for (var i = 0; i < text.length; i += 800) {
        // ignore: avoid_print
        print('SHOT $name ${text.substring(i, min(i + 800, text.length))}');
      }
    }

    Future<void> size(double width, double height) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, height * 2);
      await _wait(tester, 500);
    }

    addTearDown(tester.view.reset);
    await size(1360, 860);
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: PaperBuddyApp(state: state)),
    );
    await state.setThemeMode(ThemeMode.light);
    await shot('desktop');

    await tester.tap(find.text('Übersicht').first);
    await shot('dashboard');

    await tester.tap(find.text('Dokumente').first);
    await _wait(tester, 800);
    await tester.tap(find.text('Mietvertrag Wohnung Lindenhof').first);
    await shot('detail');
    await tester.tap(find.byType(BackButton).first);
    await _wait(tester, 800);

    await state.setThemeMode(ThemeMode.dark);
    await size(390, 844);
    await shot('mobile-dark');
  });
}
