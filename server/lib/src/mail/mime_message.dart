import 'dart:convert';
import 'dart:typed_data';

/// Ein MIME-Teil mit dekodiertem Inhalt.
class MimePart {
  MimePart(this.headers, this.body, this.children);
  final Map<String, String> headers;
  final Uint8List body;
  final List<MimePart> children;

  String get contentType => (headers['content-type'] ?? 'text/plain').split(';').first.trim().toLowerCase();
  bool get isMultipart => contentType.startsWith('multipart/');

  String? get fileName {
    final disposition = headers['content-disposition'] ?? '';
    return headerParam(disposition, 'filename') ?? headerParam(headers['content-type'] ?? '', 'name');
  }

  bool get isAttachment => (headers['content-disposition'] ?? '').toLowerCase().startsWith('attachment');
  bool get isInline => (headers['content-disposition'] ?? '').toLowerCase().startsWith('inline');

  Iterable<MimePart> get leaves sync* {
    if (children.isEmpty) {
      yield this;
    } else {
      for (final c in children) {
        yield* c.leaves;
      }
    }
  }

  String text() {
    final charset = headerParam(headers['content-type'] ?? '', 'charset')?.toLowerCase() ?? 'utf-8';
    if (charset.contains('8859') || charset.contains('latin') || charset.contains('1252')) {
      return latin1.decode(body, allowInvalid: true);
    }
    return utf8.decode(body, allowMalformed: true);
  }
}

/// Eine E-Mail mit den Feldern, die Mail-Regeln brauchen.
class MailMessage {
  MailMessage(this.root);
  final MimePart root;

  Map<String, String> get headers => root.headers;
  String get subject => decodeHeader(headers['subject'] ?? '');
  String get messageId => (headers['message-id'] ?? '').trim();
  String get to => decodeHeader(headers['to'] ?? '');
  DateTime? get date => parseRfc2822Date(headers['date']);

  /// `(Name, Adresse)` des Absenders.
  (String, String) get from {
    final raw = decodeHeader(headers['from'] ?? '');
    final m = RegExp(r'^\s*"?([^"<]*?)"?\s*<([^>]+)>').firstMatch(raw);
    if (m != null) return (m.group(1)!.trim(), m.group(2)!.trim());
    return ('', raw.trim());
  }

  /// Textinhalt (bevorzugt text/plain, sonst HTML ohne Tags).
  String get bodyText {
    final leaves = root.leaves.where((p) => p.fileName == null || !p.isAttachment).toList();
    final plain = leaves.where((p) => p.contentType == 'text/plain').map((p) => p.text()).join('\n');
    if (plain.trim().isNotEmpty) return plain;
    final html = leaves.where((p) => p.contentType == 'text/html').map((p) => p.text()).join('\n');
    return html
        .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }

  /// Dateianhänge; mit [includeInline] auch eingebettete Dateien.
  List<MimePart> attachments({bool includeInline = false}) => [
        for (final p in root.leaves)
          if (p.fileName != null && (p.isAttachment || (includeInline && (p.isInline || !p.isAttachment))))
            p,
      ];

  static MailMessage parse(Uint8List raw) => MailMessage(parsePart(raw));
}

MimePart parsePart(Uint8List raw) {
  // Kopf und Körper trennen (CRLF CRLF oder LF LF).
  var split = -1, skip = 0;
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw[i] == 10 && raw[i + 1] == 10) {
      split = i;
      skip = 2;
      break;
    }
    if (i + 3 < raw.length && raw[i] == 13 && raw[i + 1] == 10 && raw[i + 2] == 13 && raw[i + 3] == 10) {
      split = i;
      skip = 4;
      break;
    }
  }
  final headerText = latin1.decode(split < 0 ? raw : raw.sublist(0, split), allowInvalid: true);
  final body = split < 0 ? Uint8List(0) : raw.sublist(split + skip);
  final headers = _parseHeaders(headerText);
  final type = (headers['content-type'] ?? 'text/plain').toLowerCase();

  if (type.startsWith('multipart/')) {
    final boundary = headerParam(headers['content-type']!, 'boundary');
    if (boundary != null) {
      return MimePart(headers, Uint8List(0), [for (final chunk in _splitMultipart(body, boundary)) parsePart(chunk)]);
    }
  }
  if (type.startsWith('message/rfc822')) {
    return MimePart(headers, body, const []);
  }
  final encoding = (headers['content-transfer-encoding'] ?? '').trim().toLowerCase();
  return MimePart(headers, _decodeBody(body, encoding), const []);
}

Map<String, String> _parseHeaders(String text) {
  final headers = <String, String>{};
  String? last;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && last != null) {
      headers[last] = '${headers[last]} ${line.trim()}';
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    last = line.substring(0, colon).trim().toLowerCase();
    // Bei Mehrfachköpfen (z. B. Received) den ersten behalten.
    headers.putIfAbsent(last, () => line.substring(colon + 1).trim());
  }
  return headers;
}

List<Uint8List> _splitMultipart(Uint8List body, String boundary) {
  final delimiter = latin1.encode('--$boundary');
  final parts = <Uint8List>[];
  final positions = <int>[];
  outer:
  for (var i = 0; i <= body.length - delimiter.length; i++) {
    for (var j = 0; j < delimiter.length; j++) {
      if (body[i + j] != delimiter[j]) continue outer;
    }
    if (i == 0 || body[i - 1] == 10) positions.add(i);
  }
  for (var k = 0; k < positions.length; k++) {
    var start = positions[k] + delimiter.length;
    // Abschluss-Begrenzer `--boundary--`
    if (start + 1 < body.length && body[start] == 45 && body[start + 1] == 45) break;
    while (start < body.length && body[start] != 10) {
      start++;
    }
    start++;
    var end = k + 1 < positions.length ? positions[k + 1] : body.length;
    if (end > 0 && body[end - 1] == 10) end--;
    if (end > 0 && body[end - 1] == 13) end--;
    if (start < end) parts.add(body.sublist(start, end));
  }
  return parts;
}

Uint8List _decodeBody(Uint8List body, String encoding) {
  switch (encoding) {
    case 'base64':
      final cleaned = latin1.decode(body).replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
      try {
        return base64.decode(base64.normalize(cleaned));
      } on FormatException {
        return body;
      }
    case 'quoted-printable':
      return Uint8List.fromList(_decodeQuotedPrintable(latin1.decode(body)));
    default:
      return body;
  }
}

List<int> _decodeQuotedPrintable(String s, {bool header = false}) {
  final out = <int>[];
  final text = header ? s.replaceAll('_', ' ') : s.replaceAll(RegExp(r'=\r?\n'), '');
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '=' && i + 2 < text.length) {
      final v = int.tryParse(text.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        out.add(v);
        i += 2;
        continue;
      }
    }
    final unit = c.codeUnitAt(0);
    if (unit < 256) {
      out.add(unit);
    } else {
      out.addAll(utf8.encode(c));
    }
  }
  return out;
}

/// Kodierte Wörter nach RFC 2047 (`=?utf-8?B?…?=`) auflösen.
String decodeHeader(String value) {
  final joined = value.replaceAll(RegExp(r'\?=\s+=\?'), '?==?');
  return joined.replaceAllMapped(RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?='), (m) {
    final charset = m.group(1)!.toLowerCase();
    final bytes = m.group(2)!.toLowerCase() == 'b'
        ? _safeBase64(m.group(3)!)
        : _decodeQuotedPrintable(m.group(3)!, header: true);
    return charset.contains('utf') ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes, allowInvalid: true);
  });
}

List<int> _safeBase64(String s) {
  try {
    return base64.decode(base64.normalize(s));
  } on FormatException {
    return utf8.encode(s);
  }
}

/// Parameter aus einem Kopf wie `attachment; filename="a.pdf"`, inklusive
/// RFC 2231 (`filename*=UTF-8''…`, auch in Teilen `filename*0*=`).
String? headerParam(String header, String name) {
  final lower = header.toLowerCase();
  // Fortsetzungen: name*0*, name*1* …
  final continued = RegExp('$name\\*(\\d+)\\*?=("[^"]*"|[^;]+)', caseSensitive: false).allMatches(header).toList();
  if (continued.isNotEmpty) {
    continued.sort((a, b) => int.parse(a.group(1)!).compareTo(int.parse(b.group(1)!)));
    var value = continued.map((m) => m.group(2)!.replaceAll('"', '')).join();
    final ext = RegExp(r"^([^']*)'[^']*'(.*)$").firstMatch(value);
    if (ext != null) value = Uri.decodeComponent(ext.group(2)!);
    return decodeHeader(value);
  }
  final star = RegExp('$name\\*=([^;]+)', caseSensitive: false).firstMatch(header);
  if (star != null) {
    final v = star.group(1)!.trim().replaceAll('"', '');
    final ext = RegExp(r"^([^']*)'[^']*'(.*)$").firstMatch(v);
    if (ext != null) {
      final bytes = Uri.decodeQueryComponent(ext.group(2)!, encoding: latin1).codeUnits;
      return ext.group(1)!.toLowerCase().contains('utf') ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes);
    }
    return v;
  }
  if (!lower.contains('$name=')) return null;
  final m = RegExp('(?:^|[;\\s])$name=("((?:[^"\\\\]|\\\\.)*)"|[^;\\s]+)', caseSensitive: false).firstMatch(header);
  if (m == null) return null;
  return decodeHeader(m.group(2) ?? m.group(1)!);
}

DateTime? parseRfc2822Date(String? raw) {
  if (raw == null) return null;
  const months = {'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12};
  final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?').firstMatch(raw);
  if (m == null) return null;
  final month = months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  var t = DateTime.utc(int.parse(m.group(3)!), month, int.parse(m.group(1)!), int.parse(m.group(4)!),
      int.parse(m.group(5)!), int.parse(m.group(6) ?? '0'));
  final tz = m.group(7);
  if (tz != null) {
    final sign = tz.startsWith('-') ? -1 : 1;
    final offset = Duration(hours: int.parse(tz.substring(1, 3)), minutes: int.parse(tz.substring(3, 5)));
    t = sign > 0 ? t.subtract(offset) : t.add(offset);
  }
  return t;
}
