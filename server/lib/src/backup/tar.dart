import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'byte_reader.dart';

/// Schreibt ein tar-Archiv (ustar, mit PAX-Kopf für lange oder nicht-ASCII
/// Namen und große Dateien), das sich mit jedem `tar` entpacken lässt.
class TarWriter {
  TarWriter(this._out);
  final Future<void> Function(List<int> bytes) _out;

  static const _block = 512;

  /// Legt [file] unter [name] ab. Ändert sich die Datei währenddessen, wird
  /// auf die Größe vom Beginn gekürzt bzw. aufgefüllt; das Ergebnis meldet,
  /// ob alles passte.
  Future<bool> addFile(String name, File file, {void Function(List<int> chunk)? onData}) async {
    final size = await file.length();
    final modified = (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    await _header(name, size, modified);
    var written = 0;
    await for (final chunk in file.openRead()) {
      final take = chunk.length <= size - written ? chunk : chunk.sublist(0, size - written);
      if (take.isEmpty) break;
      onData?.call(take);
      await _out(take);
      written += take.length;
    }
    final complete = written == size;
    if (!complete) {
      final fill = Uint8List(size - written);
      onData?.call(fill);
      await _out(fill);
    }
    await _pad(size);
    return complete;
  }

  Future<void> addBytes(String name, List<int> bytes) async {
    await _header(name, bytes.length, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    await _out(bytes);
    await _pad(bytes.length);
  }

  /// Zwei leere Blöcke beenden das Archiv.
  Future<void> close() => _out(Uint8List(_block * 2));

  Future<void> _pad(int size) async {
    final rest = size % _block;
    if (rest != 0) await _out(Uint8List(_block - rest));
  }

  Future<void> _header(String name, int size, int mtime) async {
    final encoded = utf8.encode(name);
    final ascii = encoded.length == name.length;
    final pax = <String, String>{
      if (!ascii || encoded.length > 100) 'path': name,
      if (size > 077777777777) 'size': '$size',
    };
    if (pax.isNotEmpty) {
      final records = utf8.encode(pax.entries.map((e) => _paxRecord(e.key, e.value)).join());
      await _out(_ustar('PaxHeader/${_asciiName(name)}', records.length, mtime, 'x'.codeUnitAt(0)));
      await _out(records);
      await _pad(records.length);
    }
    await _out(_ustar(_asciiName(name), size > 077777777777 ? 0 : size, mtime, '0'.codeUnitAt(0)));
  }

  /// Ersatzname für das ustar-Feld; der echte steht dann im PAX-Kopf.
  static String _asciiName(String name) {
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7e]'), '_');
    return ascii.length <= 100 ? ascii : ascii.substring(ascii.length - 100);
  }

  /// `"<länge> <schlüssel>=<wert>\n"`, die Länge zählt sich selbst mit.
  static String _paxRecord(String key, String value) {
    final rest = ' $key=$value\n';
    final restLength = utf8.encode(rest).length;
    var length = restLength + 1;
    while ('$length'.length + restLength != length) {
      length = '$length'.length + restLength;
    }
    return '$length$rest';
  }

  static Uint8List _ustar(String name, int size, int mtime, int type) {
    final h = Uint8List(_block);
    void put(int offset, String value) => h.setRange(offset, offset + value.length, ascii.encode(value));
    String octal(int v, int width) => v.toRadixString(8).padLeft(width - 1, '0');
    put(0, name);
    put(100, '${octal(0x1a4, 8)}\x00'); // 0644
    put(108, '${octal(0, 8)}\x00');
    put(116, '${octal(0, 8)}\x00');
    put(124, '${octal(size, 12)}\x00');
    put(136, '${octal(mtime, 12)}\x00');
    put(148, '        ');
    h[156] = type;
    put(257, 'ustar\x00');
    put(263, '00');
    final sum = h.fold<int>(0, (a, b) => a + b);
    put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
    return h;
  }
}

/// Liest die Dateien eines tar-Archivs nacheinander.
class TarReader {
  TarReader(this._in);
  final ByteReader _in;

  /// Ruft [onFile] für jede Datei auf; der Inhalt kommt stückweise über den
  /// übergebenen Stream-Empfänger.
  Future<void> forEach(
    Future<void> Function(String name, int size, Future<void> Function(FutureOr<void> Function(Uint8List) sink) read)
    onFile,
  ) async {
    var pax = <String, String>{};
    while (true) {
      final header = await _in.read(512, allowShort: true);
      if (header.length < 512) throw const FormatException('Archiv ist unvollständig');
      if (header.every((b) => b == 0)) {
        // Ende: Was folgt (zweiter Nullblock, Auffüllung), muss leer sein.
        while (!await _in.atEnd()) {
          final rest = await _in.read(512, allowShort: true);
          if (rest.any((b) => b != 0)) throw const FormatException('Daten nach dem Archivende');
        }
        return;
      }
      if (!_checksumOk(header)) throw const FormatException('Archiv ist beschädigt');
      final type = header[156];
      final size = pax['size'] != null ? int.parse(pax['size']!) : _octal(header, 124, 12);
      final name = pax['path'] ?? _name(header);
      final padded = (size + 511) ~/ 512 * 512;
      if (type == 0x78) {
        pax = _parsePax(await _in.read(size));
        await _in.read(padded - size);
        continue;
      }
      pax = {};
      var consumed = false;
      if (type == 0x30 || type == 0) {
        await onFile(name, size, (sink) async {
          consumed = true;
          await _in.forward(size, sink);
        });
      }
      if (!consumed) await _in.forward(size, (_) {});
      await _in.read(padded - size);
    }
  }

  static bool _checksumOk(Uint8List h) {
    var sum = 0;
    for (var i = 0; i < 512; i++) {
      sum += (i >= 148 && i < 156) ? 32 : h[i];
    }
    return sum == _octal(h, 148, 8);
  }

  static int _octal(Uint8List h, int offset, int length) {
    final text = String.fromCharCodes(h.sublist(offset, offset + length)).replaceAll('\x00', '').trim();
    return text.isEmpty ? 0 : int.parse(text, radix: 8);
  }

  static String _name(Uint8List h) {
    String field(int offset, int length) {
      final bytes = h.sublist(offset, offset + length);
      final end = bytes.indexOf(0);
      return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end), allowMalformed: true);
    }

    final prefix = field(345, 155);
    final name = field(0, 100);
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  static Map<String, String> _parsePax(Uint8List data) {
    final out = <String, String>{};
    var i = 0;
    while (i < data.length) {
      final space = data.indexOf(32, i);
      if (space < 0) break;
      final length = int.parse(String.fromCharCodes(data, i, space));
      final record = utf8.decode(data.sublist(space + 1, i + length - 1));
      final eq = record.indexOf('=');
      if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1);
      i += length;
    }
    return out;
  }
}
