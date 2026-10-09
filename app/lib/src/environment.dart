import 'package:flutter/services.dart';

/// Welche PaperBuddy-Variante dieser Build ist: die normale App oder der
/// Entwicklungs-Build (`--dart-define=PAPERBUDDY_ENV=dev`), der daneben
/// mit eigenem Namen und eigenem Schlüsselbund-Eintrag läuft.
abstract final class AppEnv {
  /// Version der App (Git-Tag `v<version>`, wie `version` in pubspec.yaml).
  static const version = '0.2.0';

  static const name = String.fromEnvironment(
    'PAPERBUDDY_ENV',
    defaultValue: 'prod',
  );

  /// Auch die Android-Variante (`--flavor dev`).
  static const isDev = name == 'dev' || appFlavor == 'dev';

  /// Auf macOS teilen sich alle Builds den Anmelde-Schlüsselbund, darum
  /// braucht jede Variante einen eigenen Eintrag.
  static const vaultEntry = isDev ? 'paperbuddy-dev' : 'paperbuddy';
  static const appName = isDev ? 'PaperBuddy Dev' : 'PaperBuddy';
}
