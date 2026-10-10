// Anmeldung über die Oberfläche, Zwei-Faktor-Anmeldung einrichten,
// abmelden, mit Code wieder anmelden und die Sitzung behalten.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paperbuddy/src/app.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/session_store.dart';
import 'package:paperbuddy_server/src/totp.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Anmeldung mit Zwei-Faktor-Code und gespeicherter Sitzung', skip: skipWithoutServer, timeout: const Timeout(Duration(minutes: 3)), (tester) async {
    final state = await freshState();
    await state.restore();
    await desktopWindow(tester);
    await tester.pumpWidget(PaperBuddyApp(state: state));
    await pumpUntil(tester, () => shows('Server-Adresse'), reason: 'Anmeldebildschirm');

    Future<void> signIn() async {
      await tester.enterText(find.widgetWithText(TextFormField, 'Server-Adresse'), e2eServer);
      await tester.enterText(find.widgetWithText(TextFormField, 'Benutzername'), e2eUser);
      await tester.enterText(find.widgetWithText(TextFormField, 'Passwort'), e2ePassword);
      await tester.tap(find.text('Anmelden'));
    }

    await signIn();
    await pumpUntil(tester, () => state.status == SessionStatus.signedIn, reason: 'angemeldet');

    // Zwei-Faktor-Anmeldung im Profil einrichten.
    await tester.tap(find.text('Einstellungen').last);
    await pumpUntil(tester, () => shows('Profil'), reason: 'Einstellungen');
    await tester.tap(find.text('Profil'));
    await pumpUntil(tester, () => shows('Einrichten'), reason: 'Profil');
    await tester.tap(find.text('Einrichten'));
    await pumpUntil(tester, () => shows('Zwei-Faktor-Anmeldung einrichten'), reason: 'Einrichtung');
    final secret = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data!)
        .firstWhere((t) => RegExp(r'^[A-Z2-7 ]+$').hasMatch(t))
        .replaceAll(' ', '');
    await tester.enterText(find.widgetWithText(TextField, 'Code'), Totp.codeAt(secret, Totp.stepAt(DateTime.now())));
    await tester.tap(find.text('Aktivieren'));
    await pumpUntil(tester, () => shows('Wiederherstellungscodes'), reason: 'Wiederherstellungscodes');
    await tester.tap(find.text('Gespeichert'));
    await pumpUntil(tester, () => find.textContaining('Aktiv:').evaluate().isNotEmpty, reason: 'aktiv');

    // Abmelden.
    await tester.tap(find.byType(BackButton).first);
    await pumpUntil(tester, () => shows('Profil'), reason: 'zurück in den Einstellungen');
    await scrollUntilShown(tester, find.text('Profil'), find.text('Abmelden'), reason: 'Abmelden');
    await tester.tap(find.text('Abmelden'));
    await pumpUntil(tester, () => shows('Abmelden?'), reason: 'Rückfrage');
    await tester.tap(find.widgetWithText(FilledButton, 'Abmelden'));
    await pumpUntil(tester, () => state.status == SessionStatus.signedOut, reason: 'abgemeldet');

    // Wieder anmelden: erst falscher, dann richtiger Code.
    await pumpUntil(tester, () => shows('Server-Adresse'), reason: 'Anmeldebildschirm');
    await signIn();
    await pumpUntil(tester, () => shows('Bestätigungscode'), reason: 'Frage nach dem Code');
    await tester.enterText(find.widgetWithText(TextFormField, 'Bestätigungscode'), '000000');
    await tester.tap(find.text('Anmelden'));
    await pumpUntil(tester, () => shows('Der Code ist falsch oder abgelaufen.'), reason: 'falscher Code');
    // Nach dem falschen Code steht der Cursor wieder im Codefeld.
    await pumpUntil(
      tester,
      () => tester.widget<EditableText>(find.descendant(
        of: find.widgetWithText(TextFormField, 'Bestätigungscode'),
        matching: find.byType(EditableText),
      )).focusNode.hasFocus,
      reason: 'Codefeld hat den Fokus',
    );
    // Der Einrichtungs-Code ist verbraucht: der nächste Zeitschritt.
    final code = Totp.codeAt(secret, Totp.stepAt(DateTime.now()) + 1);
    await tester.enterText(find.widgetWithText(TextFormField, 'Bestätigungscode'), code);
    await pumpUntil(tester, () => shows(code), reason: 'Code eingegeben');
    await tester.tap(find.text('Anmelden'));
    await pumpUntil(tester, () => state.status == SessionStatus.signedIn, reason: 'mit Code angemeldet');

    // Nach einem Neustart der App bleibt die Sitzung bestehen.
    final restarted = AppState(SessionStore(await SharedPreferences.getInstance()));
    await restarted.restore();
    expect(restarted.status, SessionStatus.signedIn);
    expect(restarted.client.user.username, e2eUser);
  });
}
