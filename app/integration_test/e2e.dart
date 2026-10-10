// Gemeinsames für die Integrationstests: die echte App gegen einen
// Wegwerf-Server, gestartet von
//
//   tool/integration_tests.sh <macos|linux> [integration_test/<datei>]…
//
// Sitzung und Einstellungen bleiben im Arbeitsspeicher, der Zwischenspeicher
// in einem Temp-Ordner; installierte Apps und ihre Daten bleiben unberührt.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/file_cache.dart';
import 'package:paperbuddy/src/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const e2eServer = String.fromEnvironment('PAPERBUDDY_E2E_SERVER');
const e2eUser = String.fromEnvironment('PAPERBUDDY_E2E_USER', defaultValue: 'admin');
const e2ePassword = String.fromEnvironment('PAPERBUDDY_E2E_PASSWORD');

/// Ohne Server (etwa bei `flutter test integration_test`) überspringen.
const skipWithoutServer = e2eServer == '';

/// Frischer, abgemeldeter App-Zustand mit Speichern nur im Arbeitsspeicher.
Future<AppState> freshState() async {
  await initializeDateFormatting('de');
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  FileCache.testBase = await Directory.systemTemp.createTemp('paperbuddy-e2e-');
  return AppState(SessionStore(await SharedPreferences.getInstance()));
}

/// Desktop-Fenster in fester Größe, unabhängig vom Testrechner.
Future<void> desktopWindow(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
}

bool shows(String text) => find.text(text).evaluate().isNotEmpty;

/// Scrollt die Liste, in der [anchor] steht, bis [target] gebaut ist. Nicht
/// `scrollUntilVisible`: das wartet auf `pumpAndSettle`, und in der echten
/// App läuft fast immer eine Animation.
Future<void> scrollUntilShown(WidgetTester tester, Finder anchor, Finder target, {required String reason}) async {
  final list = tester.state<ScrollableState>(find.ancestor(of: anchor, matching: find.byType(Scrollable)).first);
  for (var i = 0; target.evaluate().isEmpty; i++) {
    final position = list.position;
    if (i == 30 || position.pixels >= position.maxScrollExtent) fail('Nicht gefunden beim Scrollen: $reason');
    position.jumpTo((position.pixels + 300).clamp(0, position.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 200));
  }
  // Gebaut heißt nicht sichtbar: Listen bauen etwas über den Rand hinaus.
  await reveal(tester, target);
}

/// Holt [finder] in den sichtbaren Bereich, damit ein Tippen trifft.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 300));
}

/// Zeichnet weiter, bis [done] gilt. Server und Netzwerk laufen wirklich,
/// darum in echter Zeit und mit großzügiger Grenze.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  required String reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().take(40);
      fail('Zeitüberschreitung: $reason\nSichtbar: ${texts.join(' | ')}');
    }
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await tester.pump();
}
