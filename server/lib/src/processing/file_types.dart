import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Office-Formate (OOXML und OpenDocument).
const officeMimeTypes = {
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'application/vnd.oasis.opendocument.text': 'odt',
  'application/vnd.oasis.opendocument.spreadsheet': 'ods',
  'application/vnd.oasis.opendocument.presentation': 'odp',
  'application/msword': 'doc',
  'application/vnd.ms-excel': 'xls',
  'application/vnd.ms-powerpoint': 'ppt',
};

/// Alte Binärformate: Text gibt es nur über LibreOffice.
const legacyOfficeMimeTypes = {'application/msword', 'application/vnd.ms-excel', 'application/vnd.ms-powerpoint'};

/// Erkennt den Dateityp am Inhalt; die Endung entscheidet nur, wo der
/// Inhalt mehrdeutig ist (alte Office-Formate). So landet eine falsch
/// benannte Datei trotzdem richtig.
String detectFileType(String fileName, List<int> bytes) {
  bool starts(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  final ext = p.extension(fileName).toLowerCase();
  if (starts(ascii.encode('%PDF-'))) return 'application/pdf';
  // PDFs mit vorangestelltem Müll (kommt bei Scannern vor).
  if (bytes.length > 5 && _indexOf(bytes, ascii.encode('%PDF-'), 1024) >= 0) return 'application/pdf';
  if (starts([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'image/png';
  if (starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])) return 'image/tiff';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) return 'image/webp';
  if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) return 'image/gif';
  if (starts(ascii.encode('ftyp'), 4) &&
      (starts(ascii.encode('heic'), 8) || starts(ascii.encode('heix'), 8) || starts(ascii.encode('mif1'), 8))) {
    return 'image/heic';
  }
  if (starts([0x50, 0x4B, 0x03, 0x04])) return _zipType(bytes) ?? 'application/zip';
  if (starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
    return switch (ext) {
      '.xls' => 'application/vnd.ms-excel',
      '.ppt' => 'application/vnd.ms-powerpoint',
      _ => 'application/msword',
    };
  }
  if (_looksLikeText(bytes)) {
    return switch (ext) {
      '.csv' => 'text/csv',
      '.eml' => 'message/rfc822',
      '.html' || '.htm' => 'text/html',
      _ => 'text/plain',
    };
  }
  return 'application/octet-stream';
}

/// OOXML: `[Content_Types].xml` und ein Hauptordner; OpenDocument: Eintrag
/// `mimetype` mit dem Typ als Text.
String? _zipType(List<int> bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (_) {
    return null;
  }
  final mimetype = zip.findFile('mimetype');
  if (mimetype != null) {
    final value = utf8.decode(mimetype.content as List<int>, allowMalformed: true).trim();
    if (officeMimeTypes.containsKey(value)) return value;
  }
  if (zip.findFile('[Content_Types].xml') != null) {
    final names = zip.files.map((f) => f.name);
    if (names.any((n) => n.startsWith('word/'))) return officeMimeTypes.keys.elementAt(0);
    if (names.any((n) => n.startsWith('xl/'))) return officeMimeTypes.keys.elementAt(1);
    if (names.any((n) => n.startsWith('ppt/'))) return officeMimeTypes.keys.elementAt(2);
  }
  return null;
}

bool _looksLikeText(List<int> bytes) {
  if (bytes.isEmpty) return false;
  final sample = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
  if (sample.contains(0)) return false;
  // UTF-16 mit BOM gilt auch als Text.
  if (sample.length >= 2 && ((sample[0] == 0xFF && sample[1] == 0xFE) || (sample[0] == 0xFE && sample[1] == 0xFF))) {
    return true;
  }
  var control = 0;
  for (final b in sample) {
    if (b < 0x09 || (b > 0x0D && b < 0x20)) control++;
  }
  return control <= sample.length ~/ 100;
}

int _indexOf(List<int> bytes, List<int> needle, int limit) {
  final end = (bytes.length < limit ? bytes.length : limit) - needle.length;
  outer:
  for (var i = 0; i <= end; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Text aus DOCX/XLSX/PPTX/ODT/ODS/ODP ohne externe Programme, für die
/// Volltextsuche. Liefert `null` bei alten Binärformaten oder Fehlern.
String? officeText(Uint8List bytes, String mime) {
  if (legacyOfficeMimeTypes.contains(mime)) return null;
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return null;
  }
  String? read(String name) {
    final f = zip.findFile(name);
    return f == null ? null : utf8.decode(f.content as List<int>, allowMalformed: true);
  }

  final out = StringBuffer();
  void paragraphs(String? xml, String paragraphTag, String textTag, {String? tabTag, String? breakTag}) {
    if (xml == null) return;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (_) {
      return;
    }
    for (final para in doc.descendants.whereType<XmlElement>().where((e) => e.name.qualified == paragraphTag)) {
      final line = StringBuffer();
      for (final node in para.descendants.whereType<XmlElement>()) {
        final name = node.name.qualified;
        if (name == textTag) {
          line.write(node.innerText);
        } else if (name == tabTag) {
          line.write('\t');
        } else if (name == breakTag) {
          line.write('\n');
        }
      }
      final text = line.toString().trimRight();
      if (text.isNotEmpty) out.writeln(text);
    }
  }

  switch (officeMimeTypes[mime]) {
    case 'docx':
      for (final part in [
        'word/document.xml',
        ...zip.files.map((f) => f.name).where((n) => RegExp(r'^word/(header|footer)\d*\.xml$').hasMatch(n)),
        'word/footnotes.xml',
      ]) {
        paragraphs(read(part), 'w:p', 'w:t', tabTag: 'w:tab', breakTag: 'w:br');
      }
    case 'pptx':
      final slides = zip.files.map((f) => f.name).where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n)).toList()
        ..sort((a, b) => _number(a).compareTo(_number(b)));
      for (final s in slides) {
        paragraphs(read(s), 'a:p', 'a:t');
      }
    case 'xlsx':
      _xlsxText(zip, read, out);
    case 'odt' || 'ods' || 'odp':
      final xml = read('content.xml');
      if (xml != null) {
        try {
          final doc = XmlDocument.parse(xml);
          for (final e in doc.descendants.whereType<XmlElement>().where(
            (e) => e.name.qualified == 'text:p' || e.name.qualified == 'text:h',
          )) {
            final text = e.innerText.trim();
            if (text.isNotEmpty) out.writeln(text);
          }
        } catch (_) {}
      }
  }
  final text = out.toString().trim();
  return text;
}

int _number(String name) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(name)?.group(1) ?? '') ?? 0;

/// Tabellenblätter zeilenweise, Zellen mit Tabulator getrennt.
void _xlsxText(Archive zip, String? Function(String) read, StringBuffer out) {
  final shared = <String>[];
  final sst = read('xl/sharedStrings.xml');
  if (sst != null) {
    try {
      for (final si in XmlDocument.parse(sst).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    } catch (_) {}
  }
  final sheets = zip.files.map((f) => f.name).where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(n)).toList()
    ..sort((a, b) => _number(a).compareTo(_number(b)));
  for (final name in sheets) {
    final xml = read(name);
    if (xml == null) continue;
    try {
      for (final row in XmlDocument.parse(xml).findAllElements('row')) {
        final cells = <String>[];
        for (final c in row.findElements('c')) {
          final type = c.getAttribute('t');
          final v = c.getElement('v')?.innerText;
          final value = switch (type) {
            's' => v == null ? '' : (int.tryParse(v) != null && int.parse(v) < shared.length ? shared[int.parse(v)] : ''),
            'inlineStr' => c.findAllElements('t').map((t) => t.innerText).join(),
            _ => v ?? '',
          };
          cells.add(value);
        }
        final line = cells.join('\t').trimRight();
        if (line.isNotEmpty) out.writeln(line);
      }
    } catch (_) {}
  }
}
