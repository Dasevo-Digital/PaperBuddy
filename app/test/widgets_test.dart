import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Anmelden und Dokumente sehen', (tester) async {
    final state = await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.restore();
      return s;
    });
    await tester.pumpWidget(PaperBuddyApp(state: state!));
    await tester.pumpAndSettle();

    // Leere Felder werden abgelehnt.
    await tester.tap(find.text('Anmelden'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte Adresse angeben'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server-Adresse'),
      TestServer.address,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Benutzername'),
      TestServer.username,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Passwort'),
      'falsch',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Anmelden'));
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    expect(find.text('Benutzername oder Passwort ist falsch.'), findsOneWidget);

    // Ein Dokument vorab auf dem Server anlegen.
    await tester.runAsync(() async {
      final c = server.client();
      final token = jsonDecode(
        (await c.post(
          Uri.parse('${TestServer.address}/api/token/'),
          body: {
            'username': TestServer.username,
            'password': TestServer.password,
          },
        )).body,
      )['token'];
      final file = File('${server.dir.path}/Mietvertrag.txt')
        ..writeAsStringSync('Mietvertrag Wohnung 01.04.2025');
      final task = await server.server.consumer.submit(
        file,
        originalName: 'Mietvertrag.txt',
      );
      await server.server.consumer.waitFor(task);
      expect(token, isNotEmpty);
    });

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Passwort'),
      TestServer.password,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Anmelden'));
      while (state.status != SessionStatus.signedIn) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // Liste laden lassen.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(find.text('Dokumente'), findsWidgets);
    expect(find.text('Mietvertrag'), findsOneWidget);
    expect(find.text('1 Dokument'), findsOneWidget);

    // Detailansicht öffnen.
    await tester.runAsync(() async {
      await tester.tap(find.text('Mietvertrag'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('Belegdatum'), findsOneWidget);
    expect(find.textContaining('Mietvertrag Wohnung'), findsOneWidget);
  });

  /// Angemeldete App mit zwei Dokumenten, eins davon mit Tag „Wohnen“.
  Future<AppState> signedInApp(WidgetTester tester) async {
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      final wohnen = await s.client.createTag('Wohnen');
      for (final (name, text) in [
        ('Mietvertrag', 'Mietvertrag Wohnung Kaltmiete'),
        ('Stromrechnung', 'Stromrechnung Erstattung'),
      ]) {
        final file = File('${server.dir.path}/$name.txt')
          ..writeAsStringSync(text);
        await server.server.consumer.waitFor(
          await server.server.consumer.submit(file, originalName: '$name.txt'),
        );
      }
      final docs = await s.client.documents(
        filter: const DocumentFilter(query: 'mietvertrag'),
      );
      await s.client.updateDocument(docs.results.single.id, {
        'tags': [wohnen.id],
      });
      await s.refreshLabels();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    return state;
  }

  testWidgets(
    'Suche leeren und sofort filtern übernimmt keinen alten Suchtext',
    (tester) async {
      // Hoch genug, dass die Tags im Filter-Panel ohne Scrollen sichtbar sind.
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await signedInApp(tester);
      expect(find.text('2 Dokumente'), findsOneWidget);

      await tester.enterText(find.byType(SearchBar).first, 'erstattung');
      await settle(tester, const Duration(milliseconds: 600));
      expect(find.text('1 Dokument'), findsOneWidget);

      // Leeren und ohne Wartezeit das Filter-Panel öffnen.
      await tester.tap(find.byTooltip('Suche löschen').first);
      await tester.tap(find.byTooltip('Filter').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Wohnen ('));
      await tester.tap(find.text('Anwenden'));
      await settle(tester);

      expect(find.text('Mietvertrag'), findsOneWidget);
      expect(find.text('1 Dokument'), findsOneWidget);
    },
  );

  testWidgets(
    'Wechsel zwischen breiter und schmaler Ansicht behält die Suche',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await signedInApp(tester);
      expect(find.byType(NavigationRail), findsOneWidget);

      await tester.enterText(find.byType(SearchBar).first, 'miet');
      await settle(tester, const Duration(milliseconds: 600));
      expect(find.text('1 Dokument'), findsOneWidget);

      tester.view.physicalSize = const Size(400, 850);
      await settle(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('miet'), findsOneWidget);
      expect(find.text('1 Dokument'), findsOneWidget);
    },
  );
}

/// Lässt echte Netzwerk- und Dateiarbeit laufen und zeichnet danach neu.
Future<void> settle(
  WidgetTester tester, [
  Duration wait = const Duration(milliseconds: 300),
]) async {
  await tester.runAsync(() => Future<void>.delayed(wait));
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}
