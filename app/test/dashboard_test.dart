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

  testWidgets('Gespeicherte Ansicht als Kachel in der Übersicht', (tester) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, TestServer.username, TestServer.password);
      for (final (name, text) in [
        ('strom', 'Stromrechnung September'),
        ('miete', 'Mietvertrag Wohnung'),
      ]) {
        final f = File('${server.dir.path}/$name.txt')..writeAsStringSync(text);
        await server.server.consumer.waitFor(
          await server.server.consumer.submit(f, originalName: '$name.txt'),
        );
      }
      await s.client.createSavedView(
        'Rechnungen',
        const DocumentFilter(query: 'stromrechnung'),
        showOnDashboard: true,
      );
      await s.client.createSavedView(
        'Versteckt',
        const DocumentFilter(query: 'miet'),
      );
      await s.refreshLabels();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    await tester.tap(find.text('Übersicht'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.text('Rechnungen'), findsOneWidget);
    expect(find.text('Versteckt'), findsNothing);
    expect(find.text('strom'), findsOneWidget);
    expect(find.text('miete'), findsNothing);

    await tester.tap(find.text('Alle anzeigen'));
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('1 Dokument'), findsOneWidget);
    state.notifications.stop();
  });
}
