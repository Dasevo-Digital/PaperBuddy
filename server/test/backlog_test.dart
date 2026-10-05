import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/mail/oauth.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

import 'helpers.dart';

/// PDF mit einer Seite pro Text.
Future<List<int>> makePdf(List<String> pages) async {
  final doc = pw.Document();
  for (final text in pages) {
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Text(text)));
  }
  return doc.save();
}

final _hasPdfTools = ['qpdf', 'pdftotext', 'pdfinfo'].every((t) => Process.runSync('which', [t]).exitCode == 0);

void main() {
  group('PDF bearbeiten', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    Future<Map> doc(int id) async => await env.json('GET', '/api/documents/$id/') as Map;

    test('Drehen, Seiten löschen', () async {
      final id = (await env.upload('drei.pdf', await makePdf(['Seite Eins', 'Seite Zwei', 'Seite Drei'])))!;
      final before = env.server.db.select('SELECT checksum FROM documents WHERE id = ?', [id]).first['checksum'];
      expect((await doc(id))['page_count'], 3);
      await env.json('POST', '/api/documents/bulk_edit/', body: {'documents': [id], 'method': 'rotate', 'parameters': {'degrees': 90}});
      final after = env.server.db.select('SELECT checksum FROM documents WHERE id = ?', [id]).first['checksum'];
      expect(after, isNot(before), reason: 'Datei geändert, Prüfsumme neu');
      await env.json('POST', '/api/documents/bulk_edit/',
          body: {'documents': [id], 'method': 'rotate', 'parameters': {'degrees': 45}}, status: 400);

      await env.json('POST', '/api/documents/bulk_edit/', body: {'documents': [id], 'method': 'delete_pages', 'parameters': {'pages': [2]}});
      final d = await doc(id);
      expect(d['page_count'], 2);
      expect(d['content'], contains('Seite Eins'));
      expect(d['content'], isNot(contains('Seite Zwei')));
      await env.json('POST', '/api/documents/bulk_edit/',
          body: {'documents': [id], 'method': 'delete_pages', 'parameters': {'pages': [1, 2]}}, status: 400);
      final history = await env.json('GET', '/api/documents/$id/history/') as List;
      expect(history.first['changes'], contains('checksum'));
    });

    test('Teilen und zusammenführen', () async {
      final tag = await env.json('POST', '/api/tags/', body: {'name': 'Akte'}, status: 201);
      final id = (await env.upload('akte.pdf', await makePdf(['Brief A', 'Brief B', 'Brief C']), fields: {'tags': tag['id']}))!;
      final split = await env.json('POST', '/api/documents/bulk_edit/', body: {
        'documents': [id],
        'method': 'split',
        'parameters': {'pages': '1,2-3', 'delete_originals': true},
      });
      expect(split['task_ids'], hasLength(2));
      await env.server.consumer.idle();
      final docs = (await env.json('GET', '/api/documents/?ordering=title'))['results'] as List;
      expect(docs.map((d) => d['title']), ['akte (Teil 1)', 'akte (Teil 2)']);
      expect(docs.map((d) => d['page_count']), [1, 2]);
      expect(docs.every((d) => (d['tags'] as List).contains(tag['id'])), isTrue, reason: 'Metadaten übernommen');
      expect((await env.json('GET', '/api/trash/'))['all'], [id]);

      final merged = await env.json('POST', '/api/documents/bulk_edit/', body: {
        'documents': [docs[1]['id'], docs[0]['id']],
        'method': 'merge',
        'parameters': {'metadata_document_id': docs[0]['id']},
      });
      await env.server.consumer.waitFor(merged['task_id'] as String);
      final all = (await env.json('GET', '/api/documents/?ordering=-added'))['results'] as List;
      final m = all.first;
      expect(m['page_count'], 3);
      expect(m['title'], 'akte (Teil 1)');
      expect((m['content'] as String).indexOf('Brief B'), lessThan((m['content'] as String).indexOf('Brief A')),
          reason: 'Reihenfolge wie ausgewählt');
    });
  }, skip: _hasPdfTools ? false : 'qpdf/poppler fehlen (läuft im Docker-Test)');

  group('Ordnerstruktur', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create(env: {'PAPERBUDDY_FILENAME_FORMAT': '{{ created_year }}/{{ correspondent }}/{{ title }}'}));
    tearDown(() => env.close());

    String path(int id) => env.server.db.select('SELECT original_path FROM documents WHERE id = ?', [id]).first['original_path'] as String;

    test('Ablage nach Vorlage, Umbenennen, Kollisionen, Speicherpfad, Aufräumen', () async {
      final corr = await env.json('POST', '/api/correspondents/', body: {'name': 'Stadtwerke', 'match': 'Stadtwerke', 'matching_algorithm': 1}, status: 201);
      final a = (await env.uploadText('a.txt', 'Stadtwerke 15.09.2026', fields: {'title': 'Strom/Gas: September'}))!;
      expect(path(a), 'originals/2026/Stadtwerke/Strom_Gas_ September.txt');
      final media = '${env.dir.path}/media';
      expect(File('$media/${path(a)}').existsSync(), isTrue);

      final b = (await env.uploadText('b.txt', 'Stadtwerke 01.02.2026 anderes', fields: {'title': 'Strom/Gas: September'}))!;
      expect(path(b), 'originals/2026/Stadtwerke/Strom_Gas_ September_01.txt');

      await env.json('PATCH', '/api/documents/$a/', body: {'title': 'Strom'});
      expect(path(a), 'originals/2026/Stadtwerke/Strom.txt');
      await env.json('PATCH', '/api/correspondents/${corr['id']}/', body: {'name': 'SWM'});
      expect(path(a), 'originals/2026/SWM/Strom.txt');
      expect(path(b), startsWith('originals/2026/SWM/'));
      expect(Directory('$media/originals/2026/Stadtwerke').existsSync(), isFalse, reason: 'leere Ordner entfernt');

      final sp = await env.json('POST', '/api/storage_paths/', body: {'name': 'Steuer', 'path': 'Steuer/{asn}-{title}'}, status: 201);
      await env.json('PATCH', '/api/documents/$a/', body: {'storage_path': sp['id'], 'archive_serial_number': 7});
      expect(path(a), 'originals/Steuer/7-Strom.txt');
      final download = await env.call('GET', '/api/documents/$a/download/');
      expect(await download.readAsString(), 'Stadtwerke 15.09.2026');

      // Ohne Vorlage zurück nach ID: über rename-files mit leerem Format.
      final plain = FilenameGenerator(env.server.db, env.server.store);
      env.server.db.execute('UPDATE documents SET storage_path_id = NULL');
      expect(await plain.relocateAll(), 2);
      expect(path(a), 'originals/${a.toString().padLeft(7, '0')}.txt');

      await env.json('DELETE', '/api/documents/$b/', status: 204);
      await env.json('POST', '/api/trash/', body: {'action': 'empty'});
      expect(Directory('$media/originals/2026').existsSync(), isFalse);
    });
  });

  group('Verlauf und Versionen', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    test('Verlauf zeichnet Änderungen mit Benutzer auf', () async {
      final tag = await env.json('POST', '/api/tags/', body: {'name': 'Wichtig'}, status: 201);
      final id = (await env.uploadText('v.txt', 'Inhalt'))!;
      await env.json('PATCH', '/api/documents/$id/', body: {'title': 'Neuer Titel', 'tags': [tag['id']]});
      await env.json('POST', '/api/documents/bulk_edit/', body: {'documents': [id], 'method': 'remove_tag', 'parameters': {'tag': tag['id']}});
      await env.json('DELETE', '/api/documents/$id/', status: 204);
      await env.json('POST', '/api/trash/', body: {'documents': [id], 'action': 'restore'});
      final h = await env.json('GET', '/api/documents/$id/history/') as List;
      expect(h.map((e) => e['action']), ['update', 'update', 'update', 'update', 'create']);
      expect(h.last['changes']['title'], [null, 'v']);
      final titleChange = h[3]['changes'];
      expect(titleChange['title'], ['v', 'Neuer Titel']);
      expect(titleChange['tags'], {'type': 'm2m', 'operation': 'add', 'objects': ['Wichtig']});
      expect(h[2]['changes']['tags']['operation'], 'remove');
      expect(h[1]['changes'], contains('deleted_at'));
      expect(h[0]['actor']['username'], 'admin');

      env.addUser('leser', permissions: ['view_document']);
      env.server.db.execute("UPDATE documents SET owner = (SELECT id FROM users WHERE username = 'admin')");
      await env.json('PATCH', '/api/documents/$id/', body: {
        'set_permissions': {
          'view': {'users': [env.server.db.select("SELECT id FROM users WHERE username='leser'").first['id']], 'groups': []},
          'change': {'users': [], 'groups': []},
        },
      });
      await env.json('GET', '/api/documents/$id/history/', as: 'leser', status: 403);
    });

    test('Versionen hochladen, abrufen, löschen', () async {
      final id = (await env.uploadText('vertrag.txt', 'Entwurf'))!;
      expect((await env.json('GET', '/api/documents/$id/'))['versions'], isEmpty);

      Future<Map> uploadVersion(String text, {String? label}) async {
        const b = 'vb';
        final body = [
          '--$b\r\ncontent-disposition: form-data; name="document"; filename="vertrag-neu.txt"\r\n\r\n$text\r\n',
          if (label != null) '--$b\r\ncontent-disposition: form-data; name="version_label"\r\n\r\n$label\r\n',
          '--$b--\r\n',
        ].join();
        final r = await env.call('POST', '/api/documents/$id/update_version/',
            body: utf8.encode(body), headers: {'content-type': 'multipart/form-data; boundary=$b'});
        final task = jsonDecode(await r.readAsString()) as String;
        await env.server.consumer.waitFor(task);
        return env.server.db.select('SELECT status, result FROM tasks WHERE task_id = ?', [task]).first;
      }

      expect((await uploadVersion('Unterschrieben', label: 'unterschrieben'))['status'], 'SUCCESS');
      final d = await env.json('GET', '/api/documents/$id/');
      final versions = d['versions'] as List;
      expect(versions, hasLength(2));
      expect(versions.first['is_root'], isTrue);
      expect(versions.last['version_label'], 'unterschrieben');
      expect(d['content'], 'Unterschrieben');
      expect(await (await env.call('GET', '/api/documents/$id/download/')).readAsString(), 'Unterschrieben');
      expect(await (await env.call('GET', '/api/documents/$id/download/?version=${versions.first['id']}')).readAsString(), 'Entwurf');
      expect((await env.call('GET', '/api/documents/$id/download/?version=99999')).statusCode, 404);

      final dup = await uploadVersion('Entwurf');
      expect(dup['status'], 'FAILURE', reason: 'gleiche Datei wie die Ursprungsfassung');
      final h = await env.json('GET', '/api/documents/$id/history/') as List;
      expect(h.first['changes']['version'], [null, 'unterschrieben']);

      await env.json('DELETE', '/api/documents/$id/versions/${versions.last['id']}/', status: 400);
      final rootPath = env.server.db.select('SELECT original_path FROM document_versions WHERE id = ?', [versions.first['id']]).first['original_path'] as String;
      await env.json('DELETE', '/api/documents/$id/versions/${versions.first['id']}/', status: 204);
      expect(await env.server.store.get(rootPath), isNull);
      expect((await env.json('GET', '/api/documents/$id/'))['versions'], hasLength(1));
    });
  });

  group('API v10', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    Future<dynamic> v10(String method, String path, {Object? body}) async {
      final r = await env.call(method, path, body: body, headers: {'accept': 'application/json; version=10'});
      final text = await r.readAsString();
      expect(r.statusCode, lessThan(300), reason: text);
      return text.isEmpty ? null : jsonDecode(text);
    }

    test('Aufgaben, Ansichten, text-Suche', () async {
      expect((await env.call('GET', '/api/')).headers['x-api-version'], '10');
      await env.uploadText('suche.txt', 'Grundsteuerbescheid');
      final tasks = await v10('GET', '/api/tasks/?task_type=consume_file&acknowledged=false&page_size=10');
      expect(tasks['count'], 1);
      final t = tasks['results'][0];
      expect(t['status'], 'success');
      expect(t['trigger_source'], 'api_upload');
      expect(t['input_data'], {'filename': 'suche.txt'});
      expect(t['related_document_ids'], hasLength(1));
      expect((await v10('GET', '/api/tasks/${t['id']}/'))['task_type'], 'consume_file');
      expect(await env.json('GET', '/api/tasks/'), isA<List>(), reason: 'v9 bleibt eine Liste');
      expect((await v10('GET', '/api/tasks/?task_type=train_classifier'))['count'], 0);

      final view = await env.json('POST', '/api/saved_views/', body: {'name': 'A', 'show_in_sidebar': true, 'filter_rules': []}, status: 201);
      final viewV10 = await v10('GET', '/api/saved_views/${view['id']}/');
      expect(viewV10.containsKey('show_in_sidebar'), isFalse);
      var ui = await v10('GET', '/api/ui_settings/');
      expect(ui['settings']['saved_views']['sidebar_views_visible_ids'], [view['id']]);
      await v10('POST', '/api/ui_settings/', body: {
        'settings': {'saved_views': {'sidebar_views_visible_ids': <int>[], 'dashboard_views_visible_ids': [view['id']]}},
      });
      final v9 = await env.json('GET', '/api/saved_views/${view['id']}/');
      expect(v9['show_in_sidebar'], isFalse);
      expect(v9['show_on_dashboard'], isTrue);

      expect((await v10('GET', '/api/documents/?text=grundsteuer'))['count'], 1);
    });
  });

  group('OAuth für Mailkonten', () {
    late TestEnv env;
    late HttpServer provider;
    final requests = <Map<String, String>>[];

    String idToken(String email) =>
        'x.${base64Url.encode(utf8.encode(jsonEncode({'email': email}))).replaceAll('=', '')}.y';

    setUp(() async {
      env = await TestEnv.create();
      requests.clear();
      provider = await io.serve((shelf.Request r) async {
        final form = Uri.splitQueryString(await r.readAsString());
        requests.add(form);
        if (form['grant_type'] == 'authorization_code' && form['code'] == 'gut') {
          return shelf.Response.ok(jsonEncode({
            'access_token': 'zugang-1',
            'refresh_token': 'erneuern-1',
            'expires_in': 3600,
            'id_token': idToken('ich@gmail.example'),
          }));
        }
        if (form['grant_type'] == 'refresh_token' && form['refresh_token'] == 'erneuern-1') {
          return shelf.Response.ok(jsonEncode({'access_token': 'zugang-2', 'expires_in': 3600}));
        }
        return shelf.Response(400, body: '{"error":"invalid_grant"}');
      }, 'localhost', 0);
    });
    tearDown(() async {
      await provider.close(force: true);
      await env.close();
    });

    test('Anmelde-Link, Rückruf legt Konto an, Token wird erneuert', () async {
      final oauth = MailOAuth(
        env.server.db,
        const OAuthSettings(callbackBaseUrl: 'https://docs.example.org/', gmailClientId: 'id', gmailClientSecret: 'geheim'),
        providers: {
          'gmail': OAuthProvider(
            name: 'gmail',
            accountType: 2,
            authUrl: 'https://accounts.example/auth',
            tokenUrl: 'http://localhost:${provider.port}/token',
            scope: 'mail',
            imapServer: 'imap.gmail.example',
          ),
        },
      );
      expect(oauth.authorizationUrl('outlook', 1), isNull, reason: 'nicht eingerichtet');
      final url = Uri.parse(oauth.authorizationUrl('gmail', 1)!);
      expect(url.queryParameters['redirect_uri'], 'https://docs.example.org/api/oauth/callback/');
      final state = url.queryParameters['state']!;

      final bad = await oauth.callback(shelf.Request('GET', Uri.parse('http://localhost/api/oauth/callback/?code=gut&state=falsch')));
      expect(bad.statusCode, 400);
      final ok = await oauth.callback(shelf.Request('GET', Uri.parse('http://localhost/api/oauth/callback/?code=gut&state=$state')));
      expect(ok.statusCode, 200, reason: await ok.readAsString());
      final again = await oauth.callback(shelf.Request('GET', Uri.parse('http://localhost/api/oauth/callback/?code=gut&state=$state')));
      expect(again.statusCode, 400, reason: 'state nur einmal gültig');

      final account = env.server.db.select('SELECT * FROM mail_accounts').single;
      expect(account['username'], 'ich@gmail.example');
      expect(account['account_type'], 2);
      expect(account['imap_server'], 'imap.gmail.example');
      expect(await oauth.accessToken(account), 'zugang-1');

      env.server.db.execute("UPDATE mail_accounts SET expiration = '2000-01-01T00:00:00Z'");
      final expired = env.server.db.select('SELECT * FROM mail_accounts').single;
      expect(await oauth.accessToken(expired), 'zugang-2');
      expect(requests.last['client_secret'], 'geheim');
      final api = await env.json('GET', '/api/mail_accounts/');
      expect(api['results'][0]['is_token'], isTrue);
      expect(api['results'][0]['password'], '**********');
    });

    test('Callback ist ohne Anmeldung erreichbar, Links in ui_settings', () async {
      final r = await env.call('GET', '/api/oauth/callback/?state=x', as: 'niemand');
      expect(r.statusCode, 400, reason: 'erreichbar, aber ungültiger state');
      expect((await env.json('GET', '/api/ui_settings/'))['settings'].containsKey('gmail_oauth_url'), isFalse);
    });
  });
}
