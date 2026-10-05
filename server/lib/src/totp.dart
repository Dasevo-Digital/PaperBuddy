import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Zeitbasierte Einmalcodes nach RFC 6238 (SHA-1, 6 Stellen, 30 Sekunden),
/// wie sie Authenticator-Apps erzeugen.
abstract final class Totp {
  static const period = 30;
  static const digits = 6;
  static final _random = Random.secure();
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Neuer Schlüssel (160 Bit) in Base32, wie ihn Authenticator-Apps erwarten.
  static String newSecret() =>
      base32Encode(Uint8List.fromList(List.generate(20, (_) => _random.nextInt(256))));

  static int stepAt(DateTime time) =>
      time.millisecondsSinceEpoch ~/ 1000 ~/ period;

  static String codeAt(String secret, int step) {
    final key = base32Decode(secret);
    final msg = ByteData(8)..setInt64(0, step);
    final hash = Hmac(sha1, key).convert(msg.buffer.asUint8List()).bytes;
    final offset = hash.last & 0x0f;
    final value = ((hash[offset] & 0x7f) << 24) |
        (hash[offset + 1] << 16) |
        (hash[offset + 2] << 8) |
        hash[offset + 3];
    return (value % pow(10, digits)).toString().padLeft(digits, '0');
  }

  /// Zeitschritt, zu dem [code] passt (±1 Schritt Toleranz für Uhren, die
  /// leicht falsch gehen), sonst `null`.
  static int? matchingStep(String secret, String code, {DateTime? now}) {
    final normalized = code.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(normalized)) return null;
    final current = stepAt(now ?? DateTime.now());
    for (final step in [current, current - 1, current + 1]) {
      if (_equals(codeAt(secret, step), normalized)) return step;
    }
    return null;
  }

  /// `otpauth://`-Adresse für den QR-Code.
  static String uri(String secret, {required String account, String issuer = 'PaperBuddy'}) {
    final label = '${Uri.encodeComponent(issuer)}:${Uri.encodeComponent(account)}';
    return 'otpauth://totp/$label?secret=$secret'
        '&issuer=${Uri.encodeQueryComponent(issuer)}'
        '&algorithm=SHA1&digits=$digits&period=$period';
  }

  /// Zehn Wiederherstellungscodes wie `a1b2-c3d4`, falls das Gerät mit der
  /// Authenticator-App verloren geht.
  static List<String> newRecoveryCodes([int count = 10]) => [
        for (var i = 0; i < count; i++)
          List.generate(8, (_) => '0123456789abcdefghjkmnpqrstuvwxyz'[_random.nextInt(33)])
              .join()
              .replaceRange(4, 4, '-'),
      ];

  static String hashRecoveryCode(String code) => sha256
      .convert(utf8.encode(code.toLowerCase().replaceAll(RegExp(r'[\s-]'), '')))
      .toString();

  static String base32Encode(Uint8List bytes) {
    final out = StringBuffer();
    var buffer = 0, bits = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }

  static Uint8List base32Decode(String input) {
    final clean = input.toUpperCase().replaceAll(RegExp(r'[\s=]'), '');
    final out = BytesBuilder();
    var buffer = 0, bits = 0;
    for (final ch in clean.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) throw const FormatException('Ungültiger Base32-Schlüssel');
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        out.addByte((buffer >> (bits - 8)) & 0xff);
        bits -= 8;
      }
      buffer &= (1 << bits) - 1;
    }
    return out.toBytes();
  }

  static bool _equals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
