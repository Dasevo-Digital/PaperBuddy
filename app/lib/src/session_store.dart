import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'environment.dart';

/// Gespeicherte Anmeldung: Serveradresse und Token.
class SavedSession {
  const SavedSession(this.server, this.token);
  final String server;
  final String token;
}

/// Hält den Token im Schlüsselspeicher des Systems (Keychain, Android
/// Keystore, DPAPI, Secret Service). Im Browser bleibt er nur im Speicher,
/// bis die Seite geschlossen wird.
///
/// Alle Geheimnisse liegen in einem einzigen Eintrag: Auf macOS ohne
/// Apple-Signatur gilt „Immer erlauben“ nur bis zum nächsten Update, so
/// fragt das System nur einmal.
class SessionStore {
  SessionStore(this._prefs);

  final SharedPreferences _prefs;
  static String? _webMemory;

  static const _storage = FlutterSecureStorage(
    // Alte Keychain auf macOS: braucht kein Keychain-Sharing-Entitlement,
    // funktioniert also auch mit ad-hoc signierten Builds.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Zuletzt verwendete Adresse und Benutzer, zum Vorausfüllen der Anmeldung.
  String? get lastServer => _prefs.getString('lastServer');
  String? get lastUsername => _prefs.getString('lastUsername');

  /// Bis wann Benachrichtigungen als gelesen gelten.
  DateTime? get noticesSeen =>
      DateTime.tryParse(_prefs.getString('noticesSeen') ?? '');
  Future<void> setNoticesSeen(DateTime time) =>
      _prefs.setString('noticesSeen', time.toIso8601String());

  Future<void> rememberLogin(String server, String username) async {
    await _prefs.setString('lastServer', server);
    await _prefs.setString('lastUsername', username);
  }

  Future<SavedSession?> load() async {
    final raw = kIsWeb ? _webMemory : await _read();
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return SavedSession(j['server'] as String, j['token'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SavedSession session) async {
    final raw = jsonEncode({'server': session.server, 'token': session.token});
    if (kIsWeb) {
      _webMemory = raw;
    } else {
      await _storage.write(key: AppEnv.vaultEntry, value: raw);
    }
  }

  Future<void> clear() async {
    if (kIsWeb) {
      _webMemory = null;
    } else {
      await _storage.delete(key: AppEnv.vaultEntry);
    }
  }

  Future<String?> _read() async {
    try {
      return await _storage.read(key: AppEnv.vaultEntry);
    } catch (e) {
      debugPrint('Schlüsselspeicher nicht lesbar: $e');
      return null;
    }
  }
}
