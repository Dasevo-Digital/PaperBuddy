import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  testWidgets('Zugriffe in der Detailansicht', (tester) async {
    tester.view.physicalSize = const Size(700, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(TestServer.address, TestServer.username, TestServer.password);
      final f = File('${server.dir.path}/vertrag.txt')..writeAsStringSync('Mietvertrag Wohnung');
      await server.server.consumer.waitFor(await server.server.consumer.submit(f, originalName: 'vertrag.txt'));
      final id = (await s.client.documents()).results.single.id;
      await s.client.downloadFile(id);
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester, const Duration(milliseconds: 600));

    await tester.tap(find.text('vertrag'));
    await settle(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('Zugriffe'));
    await settle(tester, const Duration(milliseconds: 500));
    expect(find.text('Heruntergeladen'), findsOneWidget);
    expect(find.textContaining('admin'), findsWidgets);
  });
}
