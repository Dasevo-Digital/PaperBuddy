import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/widgets/pdf_actions.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';

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

  test('Seitenangaben lesen', () {
    expect(PdfActionsMenu.parsePages('2, 4-5'), [2, 4, 5]);
    expect(PdfActionsMenu.parsePages('3 1 3'), [1, 3]);
    expect(PdfActionsMenu.parsePages('a, -'), isEmpty);
  });

  testWidgets('Detailansicht zeigt Versionen und Verlauf', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      final file = File('${server.dir.path}/Vertrag.txt')
        ..writeAsStringSync('Entwurf');
      await server.server.consumer.waitFor(
        await server.server.consumer.submit(file, originalName: 'Vertrag.txt'),
      );
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);
    await tester.tap(find.text('Vertrag'));
    await settle(tester);
    expect(find.text('Versionen'), findsOneWidget);
    expect(find.text('Nur die ursprüngliche Fassung'), findsOneWidget);
    expect(find.text('Neue Version'), findsOneWidget);

    // Neue Fassung über den Client, dann Ansicht neu öffnen.
    await tester.runAsync(() async {
      final id = (await state.client.documents()).results.single.id;
      await state.client.waitForTask(
        await state.client.uploadVersion(
          id,
          utf8.encode('Unterschrieben'),
          'Vertrag-v2.txt',
          label: 'unterschrieben',
        ),
      );
    });
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    await tester.tap(find.text('Vertrag'));
    await settle(tester);
    expect(find.text('unterschrieben (aktuell)'), findsOneWidget);
    expect(find.text('Ursprüngliche Fassung'), findsOneWidget);

    await tester.tap(find.text('Verlauf'));
    await settle(tester);
    expect(find.text('Angelegt'), findsOneWidget);
    expect(find.textContaining('Neue Version: unterschrieben'), findsOneWidget);
    expect(find.byType(DocumentVersion), findsNothing);
  });
}
