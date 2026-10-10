import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';
import 'security.dart';
import 'totp.dart';

class User {
  User(this.id, this.username, {required this.isSuperuser, this.scope});
  final int id;
  final String username;
  final bool isSuperuser;

  /// Gesetzt bei Integrations-Token: nur lesen, nur Dokumente mit dem Tag.
  final TokenScope? scope;
}

/// Einschränkung eines Integrations-Tokens.
class TokenScope {
  const TokenScope({required this.tokenId, required this.tagId});
  final int tokenId;
  final int tagId;
}

/// Passwort-Hashes im Django-Format `pbkdf2_sha256$<iter>$<salt>$<hash>`,
/// damit sich Benutzer später aus Paperless-ngx übernehmen lassen.
class PasswordHasher {
  static const iterations = 600000;
  static final _random = Random.secure();

  static String hash(String password, {String? salt, int iter = iterations}) {
    salt ??= base64Url
        .encode(List.generate(16, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    final derived = _pbkdf2(utf8.encode(password), utf8.encode(salt), iter, 32);
    return 'pbkdf2_sha256\$$iter\$$salt\$${base64.encode(derived)}';
  }

  static bool verify(String password, String encoded) {
    final parts = encoded.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') return false;
    final expected = hash(password, salt: parts[2], iter: int.parse(parts[1]));
    return _constantTimeEquals(expected, encoded);
  }

  static Uint8List _pbkdf2(List<int> pw, List<int> salt, int iter, int len) {
    final hmac = Hmac(sha256, pw);
    final out = BytesBuilder();
    for (var block = 1; out.length < len; block++) {
      var u = hmac.convert([
        ...salt,
        block >> 24,
        block >> 16 & 255,
        block >> 8 & 255,
        block & 255,
      ]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iter; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return out.toBytes().sublist(0, len);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Ergebnis der Prüfung des zweiten Faktors.
enum MfaCheck { ok, invalid, locked }

class AuthService {
  AuthService(this.db);
  final Database db;
  static final _random = Random.secure();

  User? _userFromRow(Row? row) => row == null
      ? null
      : User(
          row['id'] as int,
          row['username'] as String,
          isSuperuser: row['is_superuser'] == 1,
        );

  int createUser(String username, String password, {bool superuser = false}) {
    db.execute(
      'INSERT INTO users (username, password_hash, is_superuser, is_staff, date_joined) '
      'VALUES (?, ?, ?, ?, ?)',
      [username, PasswordHasher.hash(password), superuser ? 1 : 0, superuser ? 1 : 0, nowIso()],
    );
    return db.lastInsertRowId;
  }

  /// Hash im Hintergrund berechnen (PBKDF2 ist absichtlich langsam).
  Future<String> hashPassword(String password) =>
      Isolate.run(() => PasswordHasher.hash(password));

  Future<void> setPassword(int userId, String password) async {
    final hash = await hashPassword(password);
    db.execute('UPDATE users SET password_hash = ? WHERE id = ?', [hash, userId]);
    // Alte Basic-Auth-Anmeldungen nicht weiter gelten lassen.
    _basicCache.removeWhere((_, v) => v.$1 == userId);
  }

  /// Ersetzt den Token eines Benutzers (`generate_auth_token`).
  String regenerateToken(User user) {
    db.execute('DELETE FROM tokens WHERE user_id = ?', [user.id]);
    return tokenFor(user);
  }

  bool get hasUsers => db.select('SELECT 1 FROM users LIMIT 1').isNotEmpty;

  /// Bremst wiederholte Fehlversuche bei der Passwort-Anmeldung.
  LoginThrottle throttle = LoginThrottle();

  /// Vergleichswert für unbekannte Benutzer, damit die Antwortzeit nicht
  /// verrät, welche Namen es gibt. Der Hash selbst passt zu keinem Passwort,
  /// nur Format und Rundenzahl zählen.
  static const _dummyHash = 'pbkdf2_sha256\$${PasswordHasher.iterations}\$paperbuddy-dummy\$'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

  /// PBKDF2 ist absichtlich langsam; darum in einem eigenen Isolate,
  /// damit der Server währenddessen weiter antwortet.
  Future<User?> authenticate(String username, String password) async {
    final rows = db.select(
      'SELECT * FROM users WHERE username = ? AND is_active = 1',
      [username],
    );
    final hash = rows.firstOrNull?['password_hash'] as String? ?? _dummyHash;
    final ok = await Isolate.run(() => PasswordHasher.verify(password, hash));
    if (rows.isEmpty || !ok) return null;
    return _userFromRow(rows.first);
  }

  /// Wie [authenticate], aber mit [throttle] je Client-Adresse: wirft
  /// [LoginThrottled], solange Adresse oder Konto gesperrt sind.
  Future<User?> login(String username, String password, {required String address}) async {
    final wait = throttle.blockedFor(address, username);
    if (wait != null) throw LoginThrottled(wait);
    final user = await authenticate(username, password);
    if (user == null) throttle.failed(address, username);
    return user;
  }

  // Zwei-Faktor-Anmeldung --------------------------------------------------

  bool mfaEnabled(int userId) =>
      db.select('SELECT totp_secret FROM users WHERE id = ?', [userId]).firstOrNull?['totp_secret'] != null;

  /// Fehlversuche je Benutzer: nach [_maxMfaFailures] falschen Codes innerhalb
  /// von [_mfaWindow] ist der zweite Faktor für dieselbe Zeit gesperrt.
  final _mfaFailures = <int, List<DateTime>>{};
  static const _maxMfaFailures = 5;
  static const _mfaWindow = Duration(minutes: 10);

  /// Prüft einen TOTP- oder Wiederherstellungscode. Jeder TOTP-Code gilt nur
  /// einmal, ein Wiederherstellungscode wird verbraucht.
  MfaCheck verifySecondFactor(int userId, String code, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final failures = (_mfaFailures[userId] ?? [])..removeWhere((f) => t.difference(f) > _mfaWindow);
    if (failures.length >= _maxMfaFailures) return MfaCheck.locked;

    final row = db.select('SELECT totp_secret, totp_last_step FROM users WHERE id = ?', [userId]).firstOrNull;
    final secret = row?['totp_secret'] as String?;
    if (secret == null) return MfaCheck.ok;
    final step = Totp.matchingStep(secret, code, now: t);
    if (step != null && step > (row!['totp_last_step'] as int)) {
      db.execute('UPDATE users SET totp_last_step = ? WHERE id = ?', [step, userId]);
      _mfaFailures.remove(userId);
      return MfaCheck.ok;
    }
    if (step == null) {
      db.execute(
        'DELETE FROM mfa_recovery_codes WHERE user_id = ? AND code_hash = ?',
        [userId, Totp.hashRecoveryCode(code)],
      );
      if (db.updatedRows > 0) {
        _mfaFailures.remove(userId);
        return MfaCheck.ok;
      }
    }
    _mfaFailures[userId] = failures..add(t);
    return MfaCheck.invalid;
  }

  /// Schaltet TOTP mit [secret] ein, wenn [code] dazu passt, und gibt neue
  /// Wiederherstellungscodes zurück; sonst `null`.
  List<String>? enableTotp(int userId, String secret, String code) {
    final int? step;
    try {
      step = Totp.matchingStep(secret, code);
    } on FormatException {
      return null;
    }
    if (step == null) return null;
    final codes = Totp.newRecoveryCodes();
    db.execute('UPDATE users SET totp_secret = ?, totp_last_step = ? WHERE id = ?', [secret, step, userId]);
    db.execute('DELETE FROM mfa_recovery_codes WHERE user_id = ?', [userId]);
    for (final c in codes) {
      db.execute('INSERT INTO mfa_recovery_codes (user_id, code_hash) VALUES (?, ?)', [userId, Totp.hashRecoveryCode(c)]);
    }
    _basicCache.removeWhere((_, v) => v.$1 == userId);
    return codes;
  }

  void disableTotp(int userId) {
    db.execute('UPDATE users SET totp_secret = NULL, totp_last_step = 0 WHERE id = ?', [userId]);
    db.execute('DELETE FROM mfa_recovery_codes WHERE user_id = ?', [userId]);
    _mfaFailures.remove(userId);
  }

  int recoveryCodesLeft(int userId) =>
      db.select('SELECT COUNT(*) AS n FROM mfa_recovery_codes WHERE user_id = ?', [userId]).first['n'] as int;

  /// Erfolgreiche Basic-Auth-Anmeldungen kurz merken, sonst kostet jede
  /// Anfrage eine volle Passwortprüfung.
  final _basicCache = <String, (int, DateTime)>{};
  static const _basicCacheTtl = Duration(minutes: 5);

  /// Wie Django REST Framework: ein dauerhafter Token pro Benutzer.
  String tokenFor(User user) {
    final existing = db.select('SELECT key FROM tokens WHERE user_id = ?', [
      user.id,
    ]);
    if (existing.isNotEmpty) return existing.first['key'] as String;
    final key = List.generate(
      20,
      (_) => _random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute('INSERT INTO tokens (key, user_id, created) VALUES (?, ?, ?)', [
      key,
      user.id,
      nowIso(),
    ]);
    return key;
  }

  User? userForToken(String token) {
    if (token.startsWith(integrationPrefix)) return _userForIntegrationToken(token);
    return _userFromRow(
      db.select(
        'SELECT u.* FROM tokens t JOIN users u ON u.id = t.user_id '
        'WHERE t.key = ? AND u.is_active = 1',
        [token],
      ).firstOrNull,
    );
  }

  // Integrations-Token ----------------------------------------------------------

  static const integrationPrefix = 'pbi_';

  static String _hashKey(String key) => sha256.convert(utf8.encode(key)).toString();

  /// Legt ein Token für [owner] an, das nur Dokumente mit [tagId] lesen darf.
  /// Liefert den Schlüssel; gespeichert wird nur sein Hash.
  (int, String) createIntegrationToken(User owner, String name, int tagId) {
    final key = '$integrationPrefix${List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    db.execute(
      'INSERT INTO integration_tokens (name, key_hash, user_id, tag_id, created) VALUES (?, ?, ?, ?, ?)',
      [name, _hashKey(key), owner.id, tagId, nowIso()],
    );
    return (db.lastInsertRowId, key);
  }

  User? _userForIntegrationToken(String key) {
    final row = db.select(
      'SELECT u.*, t.id AS token_id, t.tag_id, t.last_used FROM integration_tokens t '
      'JOIN users u ON u.id = t.user_id WHERE t.key_hash = ? AND u.is_active = 1',
      [_hashKey(key)],
    ).firstOrNull;
    if (row == null) return null;
    // Zuletzt benutzt, höchstens einmal je Minute schreiben.
    final last = DateTime.tryParse('${row['last_used']}');
    if (last == null || DateTime.now().difference(last).inMinutes >= 1) {
      db.execute('UPDATE integration_tokens SET last_used = ? WHERE id = ?', [nowIso(), row['token_id']]);
    }
    return User(
      row['id'] as int,
      row['username'] as String,
      isSuperuser: row['is_superuser'] == 1,
      scope: TokenScope(tokenId: row['token_id'] as int, tagId: row['tag_id'] as int),
    );
  }

  /// Unterstützt `Authorization: Token …` und `Basic …` wie Paperless-ngx.
  /// Basic-Auth läuft über [login], ist also ebenfalls gebremst.
  Future<User?> userForAuthorizationHeader(String? header, {String address = 'unknown'}) async {
    if (header == null) return null;
    final space = header.indexOf(' ');
    if (space < 0) return null;
    final scheme = header.substring(0, space).toLowerCase();
    final value = header.substring(space + 1).trim();
    switch (scheme) {
      case 'token':
      case 'bearer':
        return userForToken(value);
      case 'basic':
        final cacheKey = sha256.convert(utf8.encode(value)).toString();
        final cached = _basicCache[cacheKey];
        if (cached != null && cached.$2.isAfter(DateTime.now())) {
          return _userFromRow(
            db.select('SELECT * FROM users WHERE id = ? AND is_active = 1', [
              cached.$1,
            ]).firstOrNull,
          );
        }
        try {
          final decoded = utf8.decode(base64.decode(value));
          final colon = decoded.indexOf(':');
          if (colon < 0) return null;
          final username = decoded.substring(0, colon);
          final user = await login(username, decoded.substring(colon + 1), address: address);
          // Basic-Auth kennt keinen zweiten Faktor; mit TOTP nur Token.
          if (user != null && mfaEnabled(user.id)) return null;
          if (user != null) {
            throttle.succeeded(address, username);
            _basicCache.removeWhere((_, v) => v.$2.isBefore(DateTime.now()));
            _basicCache[cacheKey] = (
              user.id,
              DateTime.now().add(_basicCacheTtl),
            );
          }
          return user;
        } on FormatException {
          return null;
        }
    }
    return null;
  }
}
