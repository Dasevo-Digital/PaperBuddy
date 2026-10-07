import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperbuddy/src/app_lock.dart';

void main() {
  testWidgets('App-Sperre: gesperrt starten, entsperren, nach Hintergrund sperren', (
    tester,
  ) async {
    var answer = true;
    var asked = 0;
    var saved = <bool>[];
    final lock = AppLock(
      enabled: true,
      saveEnabled: (v) async => saved.add(v),
      authenticate: (_) async {
        asked++;
        return answer;
      },
      isSupported: () async => true,
      lockAfter: Duration.zero,
    );
    expect(lock.locked, isTrue, reason: 'beim Start gesperrt');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LockOverlay(lock: lock, child: child!),
        home: const Scaffold(body: Text('Geheimer Vertrag')),
      ),
    );
    // Die Prüfung startet von selbst und klappt.
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(lock.locked, isFalse);
    expect(find.text('Entsperren'), findsNothing);

    // Hintergrund, dann zurück: wieder gesperrt; Abbruch hält die Sperre.
    answer = false;
    lock.paused();
    await tester.pump();
    expect(find.text('Entsperren'), findsNothing, reason: 'nur verdeckt');
    lock.resumed();
    await tester.pumpAndSettle();
    expect(lock.locked, isTrue);
    expect(find.text('Entsperren'), findsOneWidget);

    answer = true;
    await tester.tap(find.text('Entsperren'));
    await tester.pumpAndSettle();
    expect(lock.locked, isFalse);

    // Ausschalten wird gespeichert; Einschalten nur nach Prüfung.
    await lock.setEnabled(false);
    answer = false;
    expect(await lock.setEnabled(true), isFalse);
    expect(lock.enabled, isFalse);
    expect(saved, [false]);
  });
}
