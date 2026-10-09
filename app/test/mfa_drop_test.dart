import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/file_intake.dart';
import 'package:paperbuddy/src/upload_queue.dart';
import 'package:paperbuddy_server/src/totp.dart';

import 'support.dart';
import 'widgets_test.dart' show settle;

void main() {
  late TestServer server;

  setUpAll(() => initializeDateFormatting('de'));
  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  int adminId() =>
      server.server.db
              .select("SELECT id FROM users WHERE username = 'admin'")
              .first['id']
          as int;

  testWidgets('Anmeldung fragt nach dem Code der Authenticator-App', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final secret = Totp.newSecret();
    final step = Totp.stepAt(DateTime.now());
    server.server.auth.enableTotp(adminId(), secret, Totp.codeAt(secret, step));

    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.restore();
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await tester.pumpAndSettle();

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
      TestServer.password,
    );
    /// Tippt auf „Anmelden“ und wartet in echter Zeit, bis [done] gilt. Die
    /// Passwortprüfung (PBKDF2) dauert auf langsamen CI-Rechnern mehrere
    /// Sekunden; mit fester Wartezeit dreht danach noch der Ladekreis und
    /// `pumpAndSettle` läuft in den Timeout.
    Future<void> submit(bool Function() done) async {
      await tester.runAsync(() async => tester.tap(find.text('Anmelden')));
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    bool shows(String text) => find.text(text).evaluate().isNotEmpty;

    await submit(() => shows('Bestätigungscode'));
    expect(find.text('Bestätigungscode'), findsOneWidget);
    expect(state.status, SessionStatus.signedOut);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Bestätigungscode'),
      '000000',
    );
    await submit(() => shows('Der Code ist falsch oder abgelaufen.'));
    expect(find.text('Der Code ist falsch oder abgelaufen.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Bestätigungscode'),
      Totp.codeAt(secret, step + 1),
    );
    await submit(() => state.status == SessionStatus.signedIn);
    expect(
      state.status,
      SessionStatus.signedIn,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
  });

  testWidgets('Zwei-Faktor-Anmeldung im Profil einrichten', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final s = await newAppState(server);
      await s.login(
        TestServer.address,
        TestServer.username,
        TestServer.password,
      );
      return s;
    }))!;
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await settle(tester);

    await tester.tap(find.text('Einstellungen').last);
    await settle(tester);
    await tester.tap(find.text('Profil'));
    await settle(tester);
    expect(find.text('Zwei-Faktor-Anmeldung'), findsOneWidget);

    await tester.tap(find.text('Einrichten'));
    await settle(tester);
    expect(find.text('Zwei-Faktor-Anmeldung einrichten'), findsOneWidget);
    final secret = server.server.db
        .select('SELECT 1 FROM users WHERE totp_secret IS NOT NULL')
        .isEmpty;
    expect(secret, isTrue, reason: 'erst nach dem Code aktiv');

    // Den angezeigten Schlüssel lesen und daraus den Code berechnen.
    final shown = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data!)
        .firstWhere((t) => RegExp(r'^[A-Z2-7 ]+$').hasMatch(t))
        .replaceAll(' ', '');
    await tester.enterText(
      find.widgetWithText(TextField, 'Code'),
      Totp.codeAt(shown, Totp.stepAt(DateTime.now())),
    );
    await tester.tap(find.text('Aktivieren'));
    await settle(tester);
    expect(find.text('Wiederherstellungscodes'), findsOneWidget);
    await tester.tap(find.text('Gespeichert'));
    await settle(tester);
    expect(find.textContaining('Aktiv:'), findsOneWidget);
    expect(server.server.auth.mfaEnabled(adminId()), isTrue);
  });

  test('Mehrere abgelegte Dateien landen in der Warteschlange', () async {
    final state = await newAppState(server);
    await state.login(
      TestServer.address,
      TestServer.username,
      TestServer.password,
    );
    Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));
    await offerFiles(state, null, [
      (name: 'a.txt', bytes: text('Erstes Dokument vom 01.02.2026')),
      (name: 'b.txt', bytes: text('Zweites Dokument vom 02.02.2026')),
    ]);
    for (
      var i = 0;
      i < 100 && state.uploads.jobs.any((j) => !j.finished);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      [for (final j in state.uploads.jobs) j.state],
      [UploadState.done, UploadState.done],
    );
  });
}
