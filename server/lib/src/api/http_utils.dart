import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

/// Fehler im Stil von Django REST Framework (`{"detail": "…"}`).
class ApiError implements Exception {
  ApiError(this.status, this.detail, {this.body, this.headers = const {}});
  ApiError.notFound() : this(404, 'No Document matches the given query.');
  ApiError.badRequest(Object body) : this(400, 'Bad request', body: body);

  /// Wie Django REST Framework bei gedrosselten Anfragen.
  ApiError.throttled(Duration wait)
    : this(
        429,
        'Request was throttled. Expected available in ${_seconds(wait)} seconds.',
        headers: {'retry-after': '${_seconds(wait)}'},
      );

  final int status;
  final String detail;
  final Object? body;
  final Map<String, String> headers;

  static int _seconds(Duration d) => (d.inMilliseconds / 1000).ceil();

  Response toResponse() => json(body ?? {'detail': detail}, status: status).change(headers: headers);
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Response json(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// Liest JSON-, Formular- oder Multipart-Bodies in eine einheitliche Map.
/// Mehrfach vorkommende Formularfelder (z. B. `tags`) werden zu Listen.
Future<Map<String, dynamic>> readBody(Request request) async {
  final type = request.headers['content-type'] ?? '';
  if (type.startsWith('multipart/form-data')) {
    final form = await readMultipart(request);
    for (final f in form.files.values) {
      await f.file.parent.delete(recursive: true);
    }
    return form.fields;
  }
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) return {};
  if (type.startsWith('application/x-www-form-urlencoded')) {
    final result = <String, dynamic>{};
    for (final pair in raw.split('&')) {
      if (pair.isEmpty) continue;
      final i = pair.indexOf('=');
      final key = Uri.decodeQueryComponent(i < 0 ? pair : pair.substring(0, i));
      final value = i < 0
          ? ''
          : Uri.decodeQueryComponent(pair.substring(i + 1));
      _addField(result, key, value);
    }
    return result;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiError(400, 'JSON object expected.');
  } on FormatException {
    throw ApiError(400, 'JSON parse error.');
  }
}

void _addField(Map<String, dynamic> map, String key, String value) {
  final existing = map[key];
  if (existing == null) {
    map[key] = value;
  } else if (existing is List) {
    existing.add(value);
  } else {
    map[key] = [existing, value];
  }
}

class UploadedFile {
  UploadedFile(this.filename, this.file);
  final String filename;
  final File file;
}

class MultipartForm {
  final fields = <String, dynamic>{};
  final files = <String, UploadedFile>{};
}

/// Multipart-Parser, schreibt Dateien direkt in temporäre Dateien.
Future<MultipartForm> readMultipart(Request request) async {
  final contentType = ContentType.parse(request.headers['content-type']!);
  final boundary = contentType.parameters['boundary'];
  if (boundary == null) throw ApiError(400, 'Multipart boundary missing.');

  final form = MultipartForm();
  final parts = MimeMultipartTransformer(boundary).bind(request.read());
  await for (final part in parts) {
    final disposition = part.headers['content-disposition'] ?? '';
    final name = _dispositionParam(disposition, 'name');
    if (name == null) {
      await part.drain<void>();
      continue;
    }
    final filename = _dispositionParam(disposition, 'filename');
    if (filename != null) {
      final dir = await Directory.systemTemp.createTemp('paperbuddy-upload-');
      final safeName = p.basename(filename.replaceAll('\\', '/'));
      final file = File(
        p.join(dir.path, safeName.isEmpty ? 'upload' : safeName),
      );
      final sink = file.openWrite();
      await sink.addStream(part);
      await sink.close();
      form.files[name] = UploadedFile(safeName, file);
    } else {
      _addField(form.fields, name, await utf8.decodeStream(part));
    }
  }
  return form;
}

String? _dispositionParam(String header, String param) {
  final star = RegExp(
    '$param\\*=(?:UTF-8|utf-8)\'\'([^;]+)',
  ).firstMatch(header);
  if (star != null) return Uri.decodeComponent(star.group(1)!);
  final m =
      RegExp('(?:^|;)\\s*$param="((?:[^"\\\\]|\\\\.)*)"').firstMatch(header) ??
      RegExp('(?:^|;)\\s*$param=([^;]+)').firstMatch(header);
  return m?.group(1)?.replaceAll(r'\"', '"');
}

/// Paginierte Liste im Format von Paperless-ngx.
Response paginated(
  Request request,
  List<Map<String, dynamic>> Function(int limit, int offset) fetch, {
  required List<int> allIds,
  int defaultPageSize = 25,
}) {
  final q = request.url.queryParameters;
  final page = int.tryParse(q['page'] ?? '') ?? 1;
  final pageSize = (int.tryParse(q['page_size'] ?? '') ?? defaultPageSize)
      .clamp(1, 100000);
  final count = allIds.length;
  if (page < 1 || (page > 1 && (page - 1) * pageSize >= count)) {
    throw ApiError(404, 'Invalid page.');
  }
  String? link(int target) {
    final params = Map<String, String>.from(q)..['page'] = '$target';
    return request.requestedUri.replace(queryParameters: params).toString();
  }

  return json({
    'count': count,
    'next': page * pageSize < count ? link(page + 1) : null,
    'previous': page > 1 ? link(page - 1) : null,
    'all': allIds,
    'results': fetch(pageSize, (page - 1) * pageSize),
  });
}

Response emptyPage() => json({
  'count': 0,
  'next': null,
  'previous': null,
  'all': [],
  'results': [],
});

Future<Response> sendFile(
  File file,
  String contentType, {
  required String filename,
  bool inline = false,
}) async {
  final encoded = Uri.encodeComponent(filename);
  final ascii = filename.replaceAll(RegExp(r'[^\x20-\x7e]|"'), '_');
  return Response.ok(
    file.openRead(),
    headers: {
      'content-type': contentType,
      'content-length': '${await file.length()}',
      'content-disposition':
          '${inline ? 'inline' : 'attachment'}; filename="$ascii"; filename*=utf-8\'\'$encoded',
      'cache-control': 'private, max-age=3600',
    },
  );
}

// Hilfsfunktionen zum Lesen von Feldern aus Bodies und Query-Parametern.

int? asInt(Object? v) => switch (v) {
  null => null,
  int i => i,
  num n => n.toInt(),
  String s when s.isEmpty || s == 'null' => null,
  String s => int.tryParse(s) ?? (throw ApiError(400, 'Invalid integer: $s')),
  _ => throw ApiError(400, 'Invalid integer: $v'),
};

bool asBool(Object? v) => switch (v) {
  bool b => b,
  String s => s == 'true' || s == '1' || s == 'True',
  num n => n != 0,
  _ => false,
};

List<int> asIntList(Object? v) => switch (v) {
  null => [],
  List l => [for (final e in l) ?asInt(e)],
  String s when s.contains(',') => [
    for (final e in s.split(',')) ?asInt(e.trim()),
  ],
  _ => [?asInt(v)],
};

/// Akzeptiert `YYYY-MM-DD` oder volle ISO-Zeitstempel und liefert das Datum.
String? asDate(Object? v) {
  if (v == null || (v is String && v.isEmpty)) return null;
  final s = v.toString();
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(s);
  if (m == null || DateTime.tryParse(m.group(1)!) == null) {
    throw ApiError.badRequest({
      'created': ['Invalid date: $s'],
    });
  }
  return m.group(1);
}

String slugify(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[äÄ]'), 'ae')
    .replaceAll(RegExp(r'[öÖ]'), 'oe')
    .replaceAll(RegExp(r'[üÜ]'), 'ue')
    .replaceAll('ß', 'ss')
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// JSON aus einem Query-Parameter.
Object? jsonDecodeLenient(String raw) => jsonDecode(raw);
