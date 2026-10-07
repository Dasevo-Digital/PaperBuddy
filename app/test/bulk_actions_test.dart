import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Mehrfachaktionen: Speicherpfad und Freigaben', (tester) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late int bob;
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      for (final name in ['alpha', 'beta']) {
        final f = File('${server.dir.path}/$name.txt')
          ..writeAsStringSync('Dokument $name');
        await server.server.consumer.waitFor(
          await server.server.consumer.submit(f, originalName: '$name.txt'),
        );
      }
      await s.client.createStoragePath('Archiv', '{{ title }}');
      bob = (await s.client.createUser({
        'username': 'bob',
        'password': 'passwort123',
      })).id;
      await s.refreshLabels();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    Future<void> selectBoth() async {
      await tester.longPress(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta'));
      await tester.pumpAndSettle();
      expect(find.text('2 ausgewählt'), findsOneWidget);
    }

    /// Wartet, bis die Aktion durch ist (Auswahl aufgehoben).
    Future<void> done() async {
      for (
        var i = 0;
        i < 30 && find.textContaining('ausgewählt').evaluate().isNotEmpty;
        i++
      ) {
        await settle(tester, const Duration(milliseconds: 100));
      }
      expect(find.textContaining('ausgewählt'), findsNothing);
    }

    Future<void> menu(String action) async {
      await tester.tap(find.byTooltip('Weitere Aktionen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    await selectBoth();
    await menu('Speicherpfad setzen');
    await tester.tap(find.text('Archiv'));
    await done();

    await selectBoth();
    await menu('Freigaben setzen');
    await tester.tap(find.widgetWithText(FilterChip, 'bob').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await done();

    await tester.runAsync(() async {
      final docs = (await state.client.documents()).results;
      final path = state.storagePaths.values.single.id;
      expect(docs.map((d) => d.storagePath), everyElement(path));
      for (final d in docs) {
        final p = await state.client.documentPermissions(d.id);
        expect(p.viewUsers, contains(bob));
      }
    });
    state.notifications.stop();
  });
}
