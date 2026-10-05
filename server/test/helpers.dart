import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Server im Speicher mit Admin `admin`/`geheim123`.
class TestEnv {
  TestEnv._(this.dir, this.server);
  final Directory dir;
  final PaperbuddyServer server;
  final tokens = <String, String>{};

  static Future<TestEnv> create({Map<String, String> env = const {}}) async {
    final dir = await Directory.systemTemp.createTemp('paperbuddy-test-');
    final server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': dir.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
        ...env,
      }),
      database: openInMemoryDatabase(),
    );
    final e = TestEnv._(dir, server);
    e.tokens['admin'] = e.server.auth.tokenFor(_admin(e));
    return e;
  }

  static User _admin(TestEnv e) {
    final row = e.server.db.select("SELECT id FROM users WHERE username = 'admin'").first;
    return User(row['id'] as int, 'admin', isSuperuser: true);
  }

  /// Legt einen Benutzer mit Rechten an und merkt sich seinen Token.
  int addUser(String name, {List<String> permissions = const [], bool superuser = false}) {
    final id = server.auth.createUser(name, 'passwort123', superuser: superuser);
    for (final p in permissions) {
      server.db.execute('INSERT INTO user_permissions (user_id, permission) VALUES (?, ?)', [id, p]);
    }
    tokens[name] = server.auth.tokenFor(User(id, name, isSuperuser: superuser));
    return id;
  }

  Future<Response> call(String method, String path, {Object? body, String as = 'admin', Map<String, String>? headers}) =>
      Future.value(server.handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body is String || body is List<int> ? body : (body == null ? null : jsonEncode(body)),
        headers: {
          if (body != null && body is! List<int> && body is! String) 'content-type': 'application/json',
          if (tokens[as] != null) 'authorization': 'Token ${tokens[as]}',
          'accept': 'application/json; version=9',
          ...?headers,
        },
      )));

  Future<dynamic> json(String method, String path, {Object? body, int status = 200, String as = 'admin'}) async {
    final r = await call(method, path, body: body, as: as);
    final text = await r.readAsString();
    expect(r.statusCode, status, reason: '$method $path → $text');
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Upload über die API; wartet auf die Verarbeitung und liefert die Dokument-ID
  /// (oder `null` bei Fehlschlag).
  Future<int?> upload(String filename, List<int> bytes, {Map<String, Object> fields = const {}, String as = 'admin'}) async {
    const boundary = 'paperbuddy-test-boundary';
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\ncontent-disposition: form-data; name="document"; '
          'filename="$filename"\r\ncontent-type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n'));
    fields.forEach((name, value) {
      for (final v in value is List ? value : [value]) {
        body.add(utf8.encode('--$boundary\r\ncontent-disposition: form-data; name="$name"\r\n\r\n$v\r\n'));
      }
    });
    body.add(utf8.encode('--$boundary--\r\n'));
    final r = await call('POST', '/api/documents/post_document/',
        body: body.toBytes(), as: as, headers: {'content-type': 'multipart/form-data; boundary=$boundary'});
    final text = await r.readAsString();
    expect(r.statusCode, 200, reason: text);
    final taskId = jsonDecode(text) as String;
    await server.consumer.waitFor(taskId);
    final task = server.db.select('SELECT status, related_document, result FROM tasks WHERE task_id = ?', [taskId]).first;
    lastTaskResult = task['result'] as String?;
    return task['status'] == 'SUCCESS' ? task['related_document'] as int : null;
  }

  String? lastTaskResult;

  Future<int?> uploadText(String name, String text, {Map<String, Object> fields = const {}, String as = 'admin'}) =>
      upload(name, utf8.encode(text), fields: fields, as: as);

  Future<void> close() async {
    server.workflows.stop();
    server.db.close();
    await dir.delete(recursive: true);
  }
}

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
