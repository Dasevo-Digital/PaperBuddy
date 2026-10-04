import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/processing/matching.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  Logger.root.onRecord
      .where((r) => r.level >= Level.WARNING)
      .listen((r) => print('${r.level} ${r.message} ${r.error ?? ''}'));
  late Directory tmp;
  late PaperbuddyServer server;
  late String token;

  Future<Response> call(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    bool auth = true,
  }) async {
    return server.handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body is String || body is List<int>
            ? body
            : (body == null ? null : jsonEncode(body)),
        headers: {
          if (body != null && body is! List<int>)
            'content-type': 'application/json',
          if (auth) 'authorization': 'Token $token',
          'accept': 'application/json; version=9',
          ...?headers,
        },
      ),
    );
  }

  Future<dynamic> callJson(
    String method,
    String path, {
    Object? body,
    int status = 200,
  }) async {
    final r = await call(method, path, body: body);
    final text = await r.readAsString();
    expect(r.statusCode, status, reason: text);
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Baut einen multipart/form-data-Body wie ihn die iOS-Apps senden.
  Future<String> upload(
    String filename,
    List<int> bytes,
    Map<String, Object> fields,
  ) async {
    const boundary = 'paperbuddy-test-boundary';
    final body = BytesBuilder()
      ..add(
        utf8.encode(
          '--$boundary\r\ncontent-disposition: form-data; name="document"; '
          'filename="$filename"\r\ncontent-type: application/octet-stream\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n'));
    fields.forEach((name, value) {
      for (final v in value is List ? value : [value]) {
        body.add(
          utf8.encode(
            '--$boundary\r\ncontent-disposition: form-data; '
            'name="$name"\r\n\r\n$v\r\n',
          ),
        );
      }
    });
    body.add(utf8.encode('--$boundary--\r\n'));
    final r = await call(
      'POST',
      '/api/documents/post_document/',
      body: body.toBytes(),
      headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
    );
    final text = await r.readAsString();
    expect(r.statusCode, 200, reason: text);
    return jsonDecode(text) as String;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-test-');
    final config = Config.fromEnvironment({
      'PAPERBUDDY_DATA_DIR': tmp.path,
      'PAPERBUDDY_ADMIN_USER': 'admin',
      'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
    });
    server = await PaperbuddyServer.create(
      config,
      database: openInMemoryDatabase(),
    );
    final r = await call(
      'POST',
      '/api/token/',
      body: 'username=admin&password=geheim123',
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      auth: false,
    );
    token = (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  });

  tearDown(() async {
    server.db.close();
    await tmp.delete(recursive: true);
  });

  test('Anmeldung: falsches Passwort, Token, Basic Auth', () async {
    final bad = await call(
      'POST',
      '/api/token/',
      body: {'username': 'admin', 'password': 'falsch'},
      auth: false,
    );
    expect(bad.statusCode, 400);
    expect((await call('GET', '/api/documents/', auth: false)).statusCode, 401);
    final basic = await call(
      'GET',
      '/api/documents/',
      auth: false,
      headers: {
        'authorization':
            'Basic ${base64.encode(utf8.encode('admin:geheim123'))}',
      },
    );
    expect(basic.statusCode, 200);
    expect(basic.headers['x-api-version'], '9');
  });

  test('ui_settings enthält Benutzer und Berechtigungen', () async {
    final s = await callJson('GET', '/api/ui_settings/');
    expect(s['user']['username'], 'admin');
    expect(s['permissions'], contains('add_document'));
  });

  test('Upload → Task → Dokument, Tags, Suche, Bulk-Edit, Löschen', () async {
    final inbox = await callJson(
      'POST',
      '/api/tags/',
      body: {'name': 'Posteingang', 'is_inbox_tag': true, 'color': '#000000'},
      status: 201,
    );
    expect(inbox['text_color'], '#ffffff');
    final finanzen = await callJson(
      'POST',
      '/api/tags/',
      body: {'name': 'Finanzen', 'match': 'Rechnung', 'matching_algorithm': 1},
      status: 201,
    );
    final stadtwerke = await callJson(
      'POST',
      '/api/correspondents/',
      body: {
        'name': 'Stadtwerke',
        'match': 'Stadtwerke',
        'matching_algorithm': 3,
      },
      status: 201,
    );
    await callJson(
      'POST',
      '/api/tags/',
      body: {'name': 'Finanzen'},
      status: 400,
    );

    final text =
        'Stadtwerke Musterstadt\nRechnung vom 15.03.2026\nBetrag: 42,00 EUR';
    final taskId = await upload('strom.txt', utf8.encode(text), {
      'title': 'Stromrechnung',
    });
    await server.consumer.waitFor(taskId);

    final tasks = await callJson('GET', '/api/tasks/?task_id=$taskId') as List;
    expect(
      tasks.single['status'],
      'SUCCESS',
      reason: '${tasks.single['result']}',
    );
    final id = int.parse(tasks.single['related_document'] as String);

    final doc = await callJson('GET', '/api/documents/$id/');
    expect(doc['title'], 'Stromrechnung');
    expect(doc['created'], '2026-03-15');
    expect(doc['correspondent'], stadtwerke['id']);
    expect(doc['tags'], unorderedEquals([inbox['id'], finanzen['id']]));

    // Ältere API-Versionen bekommen einen Zeitstempel.
    final old = await call(
      'GET',
      '/api/documents/$id',
      headers: {'accept': 'application/json; version=5'},
    );
    expect(
      jsonDecode(await old.readAsString())['created'],
      '2026-03-15T00:00:00Z',
    );

    final dup = await upload('kopie.txt', utf8.encode(text), {});
    await server.consumer.waitFor(dup);
    final dupTask =
        (await callJson('GET', '/api/tasks/?task_id=$dup') as List).single;
    expect(dupTask['status'], 'FAILURE');
    expect(dupTask['result'], contains('duplicate'));

    final search = await callJson('GET', '/api/documents/?query=musterst');
    expect(search['count'], 1);
    expect(
      search['results'][0]['__search_hit__']['highlights'],
      contains('match'),
    );
    expect(
      (await callJson('GET', '/api/documents/?query=gibtsnicht'))['count'],
      0,
    );
    expect(
      (await callJson(
        'GET',
        '/api/documents/?tags__id__all=${finanzen['id']}',
      ))['all'],
      [id],
    );
    expect(
      (await callJson('GET', '/api/documents/?is_in_inbox=true'))['count'],
      1,
    );
    expect(
      (await callJson(
        'GET',
        '/api/documents/?created__date__gt=2026-04-01',
      ))['count'],
      0,
    );

    await callJson(
      'PATCH',
      '/api/documents/$id/',
      body: {
        'title': 'Strom März',
        'remove_inbox_tags': true,
        'archive_serial_number': 7,
      },
    );
    final patched = await callJson('GET', '/api/documents/$id/');
    expect(patched['title'], 'Strom März');
    expect(patched['tags'], [finanzen['id']]);
    expect(await callJson('GET', '/api/documents/next_asn/'), 8);
    expect(
      (await callJson('GET', '/api/documents/?query=m%C3%A4rz'))['count'],
      1,
    );

    await callJson(
      'POST',
      '/api/documents/$id/notes/',
      body: {'note': 'bezahlt'},
    );
    expect(
      (await callJson('GET', '/api/documents/$id/'))['notes'][0]['note'],
      'bezahlt',
    );

    await callJson(
      'POST',
      '/api/documents/bulk_edit/',
      body: {
        'documents': [id],
        'method': 'add_tag',
        'parameters': {'tag': inbox['id']},
      },
    );
    expect(
      (await callJson('GET', '/api/tags/${inbox['id']}/'))['document_count'],
      1,
    );

    final download = await call('GET', '/api/documents/$id/download/');
    expect(await download.readAsString(), text);
    expect(download.headers['content-disposition'], contains('strom.txt'));

    final stats = await callJson('GET', '/api/statistics/');
    expect(stats['documents_total'], 1);

    await callJson('DELETE', '/api/documents/$id/', status: 204);
    expect((await callJson('GET', '/api/documents/'))['count'], 0);
  });

  test('Tags beim Upload werden übernommen', () async {
    final a = await callJson(
      'POST',
      '/api/tags/',
      body: {'name': 'A'},
      status: 201,
    );
    final b = await callJson(
      'POST',
      '/api/tags/',
      body: {'name': 'B'},
      status: 201,
    );
    final taskId = await upload('x.txt', utf8.encode('Hallo'), {
      'tags': [a['id'], b['id']],
    });
    await server.consumer.waitFor(taskId);
    final docs = await callJson('GET', '/api/documents/');
    expect(docs['results'][0]['tags'], [a['id'], b['id']]);
  });

  test('Datumserkennung', () {
    expect(findDate('Datum: 3. Oktober 2025'), DateTime.utc(2025, 10, 3));
    expect(findDate('am 2024-02-29 bezahlt'), DateTime.utc(2024, 2, 29));
    expect(findDate('31.02.2024 ungültig'), isNull);
  });

  test('Eingangsordner übernimmt fertige Dateien', () async {
    final consumeDir = Directory('${tmp.path}/consume')..createSync();
    final watcher = ConsumeFolderWatcher(
      consumeDir.path,
      server.consumer,
      interval: const Duration(hours: 1),
    );
    File(
      '${consumeDir.path}/scan.txt',
    ).writeAsStringSync('Gescanntes Dokument');
    await watcher.scan(); // erster Durchlauf: Datei nur merken
    expect((await callJson('GET', '/api/tasks/') as List), isEmpty);
    await watcher.scan(); // unverändert → übernehmen
    final task = (await callJson('GET', '/api/tasks/') as List).single;
    await server.consumer.waitFor(task['task_id'] as String);
    expect(File('${consumeDir.path}/scan.txt').existsSync(), isFalse);
    expect((await callJson('GET', '/api/documents/'))['count'], 1);
  });
}
