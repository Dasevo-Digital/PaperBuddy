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

  testWidgets('Vorschläge beim Bearbeiten übernehmen', (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      final file = File('${server.dir.path}/strom.txt')
        ..writeAsStringSync('Stadtwerke Musterstadt Stromrechnung');
      await server.server.consumer.waitFor(
        await server.server.consumer.submit(file, originalName: 'strom.txt'),
      );
      // Erst nach dem Import angelegt: daher nicht zugeordnet, aber vorgeschlagen.
      await s.client.createLabel(LabelKind.correspondent, {
        'name': 'Stadtwerke',
        'match': 'Stadtwerke',
        'matching_algorithm': 1,
      });
      await s.refreshLabels();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    await tester.tap(find.text('strom'));
    await settle(tester);
    await tester.tap(find.byTooltip('Bearbeiten'));
    await settle(tester, const Duration(milliseconds: 500));

    expect(find.text('Vorschläge'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, 'Stadtwerke'));
    await tester.pumpAndSettle();
    expect(find.text('Vorschläge'), findsNothing, reason: 'übernommen');
    expect(find.text('Stadtwerke'), findsOneWidget, reason: 'im Feld');
    state.notifications.stop();
  });
}
