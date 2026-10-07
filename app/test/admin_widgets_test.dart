import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/screens/admin/labels_screen.dart';
import 'package:paperbuddy/src/screens/admin/trash_screen.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';

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

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  Future<AppState> signIn(
    WidgetTester tester, {
    String user = TestServer.username,
    String password = TestServer.password,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, user, password);
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    return state;
  }

  Future<int> addDocument(
    WidgetTester tester,
    String name,
    String text,
  ) async => (await tester.runAsync(() async {
    final file = File('${server.dir.path}/$name')..writeAsStringSync(text);
    final task = await server.server.consumer.submit(file, originalName: name);
    await server.server.consumer.waitFor(task);
    return server.server.db.select(
          'SELECT related_document FROM tasks WHERE task_id = ?',
          [task],
        ).first['related_document']
        as int;
  }))!;

  testWidgets('Verwaltung je nach Rechten', (tester) async {
    await signIn(tester);
    await tester.tap(find.text('Einstellungen'));
    await settle(tester);
    for (final entry in [
      'Tags',
      'Custom Fields',
      'Workflows',
      'E-Mail-Abruf',
      'Benutzer und Gruppen',
      'Papierkorb',
    ]) {
      expect(find.text(entry), findsOneWidget, reason: entry);
    }

    // Eingeschränkter Benutzer sieht nur, was er darf.
    await tester.runAsync(() async {
      final id = server.server.auth.createUser('leser', 'passwort123');
      for (final p in ['view_document', 'view_tag']) {
        server.server.db.execute(
          'INSERT INTO user_permissions (user_id, permission) VALUES (?, ?)',
          [id, p],
        );
      }
    });
    await tester.pumpWidget(const SizedBox());
    await signIn(tester, user: 'leser', password: 'passwort123');
    await tester.tap(find.text('Einstellungen'));
    await settle(tester);
    expect(find.text('Tags'), findsOneWidget);
    expect(find.text('Workflows'), findsNothing);
    expect(find.text('Benutzer und Gruppen'), findsNothing);
    expect(find.text('Papierkorb'), findsNothing);
    expect(
      find.text('Neu'),
      findsNothing,
      reason: 'ohne add_document kein Upload-Knopf',
    );
  });

  testWidgets('Tag mit lernender Zuordnung anlegen', (tester) async {
    final state = await signIn(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const LabelsScreen(kind: LabelKind.tag),
      ),
    );
    await settle(tester);
    expect(find.text('Keine Tags'), findsOneWidget);
    await tester.tap(find.byTooltip('Tag anlegen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Versicherung',
    );
    await tester.tap(find.text('Speichern'));
    await settle(tester);
    expect(find.text('Versicherung'), findsOneWidget);
    expect(find.textContaining('Automatisch (lernend)'), findsOneWidget);
    await settle(tester);
    expect(state.tags.values.single.name, 'Versicherung');
  });

  testWidgets('Papierkorb: Dokument wiederherstellen', (tester) async {
    final id = await addDocument(tester, 'alt.txt', 'Altes Dokument');
    final state = await signIn(tester);
    await tester.runAsync(() => state.client.deleteDocument(id));
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const TrashScreen()));
    await settle(tester);
    expect(find.text('alt'), findsOneWidget);
    await tester.tap(find.byTooltip('Wiederherstellen'));
    await settle(tester);
    expect(find.text('Der Papierkorb ist leer.'), findsOneWidget);
    final doc = await tester.runAsync(() => state.client.document(id));
    expect(doc!.deletedAt, isNull);
  });

  testWidgets('Ansicht speichern und wieder anwenden', (tester) async {
    await addDocument(tester, 'Mietvertrag.txt', 'Mietvertrag Wohnung');
    await addDocument(tester, 'Strom.txt', 'Stromrechnung');
    final state = await signIn(tester);
    expect(find.text('2 Dokumente'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar).first, 'miet');
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('1 Dokument'), findsOneWidget);
    await tester.tap(find.text('Ansicht speichern'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Wohnen');
    await tester.tap(find.text('Speichern'));
    await settle(tester);
    expect(state.savedViews.single.name, 'Wohnen');

    // Suche leeren, dann Ansicht antippen.
    await tester.tap(find.byTooltip('Suche löschen').first);
    await settle(tester);
    expect(find.text('2 Dokumente'), findsOneWidget);
    await tester.tap(find.text('Wohnen'));
    await settle(tester);
    expect(find.text('1 Dokument'), findsOneWidget);
    expect(
      find.text('miet'),
      findsOneWidget,
      reason: 'Suchfeld zeigt den Begriff der Ansicht',
    );
  });
}
