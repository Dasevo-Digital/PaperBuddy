import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';

class User {
  User(this.id, this.username, {required this.isSuperuser});
  final int id;
  final String username;
  final bool isSuperuser;
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
      'INSERT INTO users (username, password_hash, is_superuser, date_joined) '
      'VALUES (?, ?, ?, ?)',
      [username, PasswordHasher.hash(password), superuser ? 1 : 0, nowIso()],
    );
    return db.lastInsertRowId;
  }

  bool get hasUsers => db.select('SELECT 1 FROM users LIMIT 1').isNotEmpty;

  /// PBKDF2 ist absichtlich langsam; darum in einem eigenen Isolate,
  /// damit der Server währenddessen weiter antwortet.
  Future<User?> authenticate(String username, String password) async {
    final rows = db.select(
      'SELECT * FROM users WHERE username = ? AND is_active = 1',
      [username],
    );
    if (rows.isEmpty) return null;
    final hash = rows.first['password_hash'] as String;
    if (!await Isolate.run(() => PasswordHasher.verify(password, hash))) {
      return null;
    }
    return _userFromRow(rows.first);
  }

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

  User? userForToken(String token) => _userFromRow(
    db.select(
      'SELECT u.* FROM tokens t JOIN users u ON u.id = t.user_id '
      'WHERE t.key = ? AND u.is_active = 1',
      [token],
    ).firstOrNull,
  );

  /// Unterstützt `Authorization: Token …` und `Basic …` wie Paperless-ngx.
  Future<User?> userForAuthorizationHeader(String? header) async {
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
          final user = await authenticate(
            decoded.substring(0, colon),
            decoded.substring(colon + 1),
          );
          if (user != null) {
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
