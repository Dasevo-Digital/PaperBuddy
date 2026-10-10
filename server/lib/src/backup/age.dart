import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'byte_reader.dart';

/// Verschlüsselung im Format von age (https://age-encryption.org/v1) mit
/// Passphrase: scrypt für den Schlüssel, ChaCha20-Poly1305 in Blöcken zu
/// 64 KiB. Eine so verschlüsselte Sicherung lässt sich auch ohne PaperBuddy
/// mit `age -d` öffnen.
abstract final class Age {
  static const _version = 'age-encryption.org/v1';
  static const _scryptLabel = 'age-encryption.org/v1/scrypt';
  static const chunkSize = 64 * 1024;
  static const _tagSize = 16;

  /// Standard von age; braucht rund 256 MB Arbeitsspeicher.
  static const defaultWorkFactor = 18;

  /// Obergrenze beim Entschlüsseln (2^20 ≈ 1 GB Arbeitsspeicher).
  static const maxWorkFactor = 20;

  static final _random = Random.secure();

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  static String _b64(List<int> bytes) => base64.encode(bytes).replaceAll('=', '');

  static Uint8List _unb64(String s) {
    if (s.contains('=') || s.contains(RegExp(r'\s'))) throw const FormatException('Ungültiges Base64');
    return base64.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
  }

  /// HKDF-SHA256 (RFC 5869); ein leeres Salz entspricht 32 Nullbytes.
  static Uint8List _hkdf(List<int> ikm, List<int> salt, String info) {
    final prk = Hmac(sha256, salt.isEmpty ? List.filled(32, 0) : salt).convert(ikm).bytes;
    return Uint8List.fromList(Hmac(sha256, prk).convert([...utf8.encode(info), 1]).bytes);
  }

  /// ChaCha20-Poly1305 (RFC 8439). Nicht `process()` von pointycastle: das
  /// lässt bei AEAD-Verfahren `doFinal` und damit den Tag weg.
  static Uint8List _seal(Uint8List key, Uint8List nonce, Uint8List data) {
    final cipher = _cipher(true, key, nonce);
    final out = Uint8List(cipher.getOutputSize(data.length));
    var n = cipher.processBytes(data, 0, data.length, out, 0);
    n += cipher.doFinal(out, n);
    return Uint8List.sublistView(out, 0, n);
  }

  /// Entschlüsselt und prüft den Tag; `null`, wenn er nicht passt.
  static Uint8List? _open(Uint8List key, Uint8List nonce, Uint8List data) {
    if (data.length < _tagSize) return null;
    final cipher = _cipher(false, key, nonce);
    final out = Uint8List(data.length - _tagSize);
    try {
      var n = cipher.processBytes(data, 0, data.length, out, 0);
      n += cipher.doFinal(out, n);
      return Uint8List.sublistView(out, 0, n);
    } on ArgumentError {
      // So meldet pointycastle einen falschen Tag.
      return null;
    }
  }

  static ChaCha20Poly1305 _cipher(bool encrypt, Uint8List key, Uint8List nonce) =>
      ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
        ..init(encrypt, AEADParameters(KeyParameter(key), _tagSize * 8, nonce, Uint8List(0)));

  /// scrypt ist absichtlich langsam und speicherhungrig, darum im eigenen
  /// Isolate.
  static Future<Uint8List> _scrypt(String passphrase, Uint8List salt, int logN) => Isolate.run(() {
    final kdf = Scrypt()
      ..init(ScryptParameters(1 << logN, 8, 1, 32, Uint8List.fromList([...utf8.encode(_scryptLabel), ...salt])));
    return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
  });

  static Uint8List _chunkNonce(int counter, bool last) {
    final nonce = Uint8List(12);
    var c = counter;
    for (var i = 10; i >= 0 && c > 0; i--) {
      nonce[i] = c & 0xff;
      c >>= 8;
    }
    nonce[11] = last ? 1 : 0;
    return nonce;
  }

  /// Schreibt eine verschlüsselte Datei nach [out]; Klartext über
  /// [AgeWriter.add], am Ende [AgeWriter.close].
  static Future<AgeWriter> writer(
    RandomAccessFile out,
    String passphrase, {
    int workFactor = defaultWorkFactor,
  }) async {
    if (passphrase.isEmpty) throw ArgumentError('Passphrase fehlt');
    final fileKey = _randomBytes(16);
    final salt = _randomBytes(16);
    final wrapKey = await _scrypt(passphrase, salt, workFactor);
    final body = _b64(_seal(wrapKey, Uint8List(12), fileKey));
    final header = '$_version\n-> scrypt ${_b64(salt)} $workFactor\n${_wrap(body)}---';
    final mac = Hmac(sha256, _hkdf(fileKey, const [], 'header')).convert(utf8.encode(header)).bytes;
    final nonce = _randomBytes(16);
    await out.writeFrom(utf8.encode('$header ${_b64(mac)}\n'));
    await out.writeFrom(nonce);
    return AgeWriter._(out, _hkdf(fileKey, nonce, 'payload'));
  }

  /// Zeilen zu 64 Zeichen; die letzte ist kürzer (notfalls leer).
  static String _wrap(String body) {
    final lines = [for (var i = 0; i < body.length; i += 64) body.substring(i, min(i + 64, body.length))];
    if (body.length % 64 == 0) lines.add('');
    return '${lines.join('\n')}\n';
  }

  /// Entschlüsselt [input] und liefert den Klartext. Falsche Passphrase oder
  /// veränderte Daten führen zu einer [AgeException].
  static Stream<Uint8List> decrypt(Stream<List<int>> input, String passphrase) async* {
    final reader = ByteReader(input);
    try {
      final payloadKey = await _readHeader(reader, passphrase);
      for (var counter = 0;; counter++) {
        final chunk = await reader.read(chunkSize + _tagSize, allowShort: true);
        final last = await reader.atEnd();
        if (chunk.length < _tagSize || (!last && chunk.length < chunkSize + _tagSize)) {
          throw AgeException('Datei ist unvollständig');
        }
        final plain = _open(payloadKey, _chunkNonce(counter, last), chunk);
        if (plain == null) throw AgeException('Daten sind beschädigt oder verändert');
        if (last && plain.isEmpty && counter > 0) throw AgeException('Leerer Schlussblock');
        yield plain;
        if (last) return;
      }
    } finally {
      await reader.cancel();
    }
  }

  static Future<Uint8List> _readHeader(ByteReader reader, String passphrase) async {
    Future<String> line() async {
      final l = await reader.readLine();
      if (l == null) throw AgeException('Keine age-Datei');
      return l;
    }

    final lines = <String>[];
    if ((await line()) != _version) throw AgeException('Keine age-Datei (age-encryption.org/v1)');
    lines.add(_version);
    final stanzas = <(List<String>, String)>[];
    String mac;
    while (true) {
      final l = await line();
      if (l.startsWith('--- ')) {
        lines.add('---');
        mac = l.substring(4);
        break;
      }
      if (!l.startsWith('-> ')) throw AgeException('Ungültiger Kopf');
      lines.add(l);
      final body = StringBuffer();
      while (true) {
        final b = await line();
        lines.add(b);
        body.write(b);
        if (b.length < 64) break;
      }
      stanzas.add((l.substring(3).split(' '), body.toString()));
    }
    if (stanzas.length != 1 || stanzas.single.$1.first != 'scrypt') {
      throw AgeException('Datei ist nicht mit einer Passphrase verschlüsselt');
    }
    final (args, body) = stanzas.single;
    final logN = args.length == 3 ? int.tryParse(args[2]) : null;
    if (logN == null || logN < 1 || logN > maxWorkFactor || args[2] != '$logN') {
      throw AgeException('Ungültiger scrypt-Arbeitsfaktor');
    }
    final Uint8List? fileKey;
    try {
      final wrapKey = await _scrypt(passphrase, _unb64(args[1]), logN);
      fileKey = _open(wrapKey, Uint8List(12), _unb64(body));
    } on FormatException {
      throw AgeException('Ungültiger Kopf');
    }
    if (fileKey == null || fileKey.length != 16) throw AgeException('Falsche Passphrase');
    final expected = Hmac(sha256, _hkdf(fileKey, const [], 'header')).convert(utf8.encode(lines.join('\n'))).bytes;
    final Uint8List given;
    try {
      given = _unb64(mac);
    } on FormatException {
      throw AgeException('Ungültiger Kopf');
    }
    if (!_equal(expected, given)) throw AgeException('Kopf ist verändert');
    final nonce = await reader.read(16, allowShort: true);
    if (nonce.length != 16) throw AgeException('Datei ist unvollständig');
    return _hkdf(fileKey, nonce, 'payload');
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Nimmt Klartext entgegen und schreibt ihn in Blöcken verschlüsselt.
class AgeWriter {
  AgeWriter._(this._out, this._key);
  final RandomAccessFile _out;
  final Uint8List _key;
  final _pending = BytesBuilder(copy: false);
  var _counter = 0;
  var _closed = false;

  /// Hält immer mindestens einen Block zurück: erst [close] weiß, welcher
  /// der letzte ist.
  Future<void> add(List<int> data) async {
    if (_closed) throw StateError('Bereits geschlossen');
    _pending.add(data);
    if (_pending.length <= Age.chunkSize) return;
    final bytes = _pending.takeBytes();
    var offset = 0;
    while (bytes.length - offset > Age.chunkSize) {
      await _write(Uint8List.sublistView(bytes, offset, offset + Age.chunkSize), last: false);
      offset += Age.chunkSize;
    }
    _pending.add(Uint8List.sublistView(bytes, offset));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _write(_pending.takeBytes(), last: true);
  }

  Future<void> _write(Uint8List chunk, {required bool last}) async {
    await _out.writeFrom(Age._seal(_key, Age._chunkNonce(_counter++, last), chunk));
  }
}

class AgeException implements Exception {
  AgeException(this.message);
  final String message;
  @override
  String toString() => message;
}
