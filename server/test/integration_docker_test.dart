@Tags(['docker'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Integrationstests gegen echte Dienste. Start der Container:
///
///   docker run -d --name pb-s3 -p 9100:9000 -e RUSTFS_ACCESS_KEY=minio -e RUSTFS_SECRET_KEY=minio12345 rustfs/rustfs
///   docker run -d --name pb-webdav -p 9200:80 -e AUTH_TYPE=Basic -e USERNAME=dav -e PASSWORD=dav12345 bytemark/webdav
///   docker run -d --name pb-mail -p 3143:3143 -p 3025:3025 \
///     -e GREENMAIL_OPTS="-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.auth.disabled" greenmail/standalone
///
/// Ausführen: PAPERBUDDY_IT=1 dart test -t docker
final _enabled = Platform.environment['PAPERBUDDY_IT'] == '1';

Future<void> _storeRoundtrip(BlobStore store, String dir) async {
  final file = File('$dir/quelle.txt')..writeAsStringSync('Inhalt mit Umlauten äöü');
  const key = 'originals/Ordner mit Leerzeichen/Datei ä.txt';
  await store.put(key, file);
  // Zwischenspeicher leeren, damit wirklich vom Server geladen wird.
  final cache = Directory('$dir/cache');
  if (cache.existsSync()) cache.deleteSync(recursive: true);
  final back = await store.get(key);
  expect(back, isNotNull);
  expect(back!.readAsStringSync(), 'Inhalt mit Umlauten äöü');
  expect(await store.get('originals/gibt-es-nicht.pdf'), isNull);
  await store.delete(key);
  if (cache.existsSync()) cache.deleteSync(recursive: true);
  expect(await store.get(key), isNull);
}

/// Kompletter Ablauf über die API mit dem gegebenen Speicher.
Future<void> _serverWithStore(Map<String, String> env) async {
  final e = await TestEnv.create(env: env);
  addTearDown(e.close);
  final id = (await e.uploadText('remote.txt', 'Liegt im entfernten Speicher'))!;
  final cache = Directory('${e.dir.path}/cache');
  if (cache.existsSync()) cache.deleteSync(recursive: true);
  final r = await e.call('GET', '/api/documents/$id/download/');
  expect(await r.readAsString(), 'Liegt im entfernten Speicher');
  final key = e.server.db.select('SELECT original_path FROM documents WHERE id = ?', [id]).first['original_path'] as String;
  await e.json('DELETE', '/api/documents/$id/', status: 204);
  await e.json('POST', '/api/trash/', body: {'action': 'empty'});
  if (cache.existsSync()) cache.deleteSync(recursive: true);
  expect(await e.server.store.get(key), isNull);
}

Future<void> _sendMail(String to, String subject, String body, {String? attachmentName, List<int>? attachment}) async {
  final socket = await Socket.connect('localhost', 3025);
  final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
  Future<String> expectCode(String code) async {
    while (true) {
      final l = await lines.first;
      if (l.startsWith('$code ')) return l;
      if (!l.startsWith('$code-')) throw StateError('SMTP: $l');
    }
  }

  await expectCode('220');
  socket.write('HELO test\r\n');
  await expectCode('250');
  socket.write('MAIL FROM:<rechnung@stadtwerke.example>\r\n');
  await expectCode('250');
  socket.write('RCPT TO:<$to>\r\n');
  await expectCode('250');
  socket.write('DATA\r\n');
  await expectCode('354');
  final b = 'B${DateTime.now().microsecondsSinceEpoch}';
  socket.write([
    'From: Stadtwerke Musterstadt <rechnung@stadtwerke.example>',
    'To: $to',
    'Subject: $subject',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="$b"',
    '',
    '--$b',
    'Content-Type: text/plain; charset=utf-8',
    '',
    body,
    if (attachment != null) ...[
      '--$b',
      'Content-Type: text/plain; name="$attachmentName"',
      'Content-Disposition: attachment; filename="$attachmentName"',
      'Content-Transfer-Encoding: base64',
      '',
      base64.encode(attachment),
    ],
    '--$b--',
    '.',
    '',
  ].join('\r\n'));
  await expectCode('250');
  socket.write('QUIT\r\n');
  await socket.close();
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('paperbuddy-it-'));
  tearDown(() => tmp.delete(recursive: true));

  group('S3', () {
    const s3 = {
      'PAPERBUDDY_STORAGE_BACKEND': 's3',
      'PAPERBUDDY_S3_ENDPOINT': 'http://localhost:9100',
      'PAPERBUDDY_S3_BUCKET': 'paperbuddy-test',
      'PAPERBUDDY_S3_ACCESS_KEY': 'minio',
      'PAPERBUDDY_S3_SECRET_KEY': 'minio12345',
      'PAPERBUDDY_S3_PREFIX': 'it',
    };

    test('Bucket anlegen, speichern, laden, löschen', () async {
      final store = S3BlobStore(
        endpoint: Uri.parse('http://localhost:9100'),
        bucket: 'paperbuddy-store-${DateTime.now().millisecondsSinceEpoch}',
        region: 'us-east-1',
        accessKey: 'minio',
        secretKey: 'minio12345',
        cacheDir: '${tmp.path}/cache',
      );
      await store.check();
      await _storeRoundtrip(store, tmp.path);
    });

    test('Falsches Passwort wird abgelehnt', () async {
      final store = S3BlobStore(
        endpoint: Uri.parse('http://localhost:9100'),
        bucket: 'paperbuddy-test',
        region: 'us-east-1',
        accessKey: 'minio',
        secretKey: 'falsch',
        cacheDir: '${tmp.path}/cache',
      );
      await expectLater(store.check(), throwsA(isA<HttpException>()));
    });

    test('Server mit S3-Speicher', () => _serverWithStore(s3));
  }, skip: _enabled ? false : 'PAPERBUDDY_IT=1 setzen');

  group('WebDAV', () {
    test('Ordner anlegen, speichern, laden, löschen', () async {
      final store = WebDavBlobStore(
        baseUrl: Uri.parse('http://localhost:9200/paperbuddy-${DateTime.now().millisecondsSinceEpoch}'),
        username: 'dav',
        password: 'dav12345',
        cacheDir: '${tmp.path}/cache',
      );
      await store.check();
      await _storeRoundtrip(store, tmp.path);
    });

    test('Server mit WebDAV-Speicher', () => _serverWithStore({
          'PAPERBUDDY_STORAGE_BACKEND': 'webdav',
          'PAPERBUDDY_WEBDAV_URL': 'http://localhost:9200/paperbuddy-server',
          'PAPERBUDDY_WEBDAV_USER': 'dav',
          'PAPERBUDDY_WEBDAV_PASSWORD': 'dav12345',
        }));
  }, skip: _enabled ? false : 'PAPERBUDDY_IT=1 setzen');

  group('IMAP', () {
    test('Konto testen, Regel anwenden, nicht doppelt übernehmen', () async {
      final env = await TestEnv.create();
      addTearDown(env.close);
      final mailbox = 'inbox${DateTime.now().millisecondsSinceEpoch}@localhost';
      await _sendMail(mailbox, 'Ihre Rechnung für März', 'Anbei die Rechnung.',
          attachmentName: 'rechnung-maerz.txt', attachment: utf8.encode('Rechnung März 2026 Betrag 87,40'));
      await _sendMail(mailbox, 'Newsletter', 'Nichts Wichtiges', attachmentName: 'werbung.txt', attachment: utf8.encode('Werbung'));

      final account = {
        'name': 'Test',
        'imap_server': 'localhost',
        'imap_port': 3143,
        'imap_security': 1,
        'username': mailbox,
        'password': mailbox,
      };
      final test = await env.json('POST', '/api/mail_accounts/test/', body: account);
      expect(test['folders'], contains('INBOX'));
      await env.json('POST', '/api/mail_accounts/test/', body: {...account, 'imap_port': 1}, status: 400);

      final acc = await env.json('POST', '/api/mail_accounts/', body: account, status: 201);
      expect(acc['password'], '**********');
      final tag = await env.json('POST', '/api/tags/', body: {'name': 'Mail'}, status: 201);
      await env.json('POST', '/api/mail_rules/', body: {
        'name': 'Rechnungen',
        'account': acc['id'],
        'filter_subject': 'Rechnung',
        'action': 3,
        'assign_title_from': 1,
        'assign_correspondent_from': 3,
        'assign_tags': [tag['id']],
      }, status: 201);

      final n = await env.json('POST', '/api/mail_accounts/${acc['id']}/process/');
      expect(n['consumed'], 1);
      await env.server.consumer.idle();
      final docs = await env.json('GET', '/api/documents/');
      expect(docs['count'], 1);
      final d = docs['results'][0];
      expect(d['title'], 'Ihre Rechnung für März');
      expect(d['tags'], [tag['id']]);
      expect(d['content'], contains('87,40'));
      final corr = await env.json('GET', '/api/correspondents/${d['correspondent']}/');
      expect(corr['name'], 'Stadtwerke Musterstadt');

      // Zweiter Abruf: Mail ist gelesen und protokolliert.
      expect((await env.json('POST', '/api/mail_accounts/${acc['id']}/process/'))['consumed'], 0);
      final processed = await env.json('GET', '/api/processed_mail/');
      expect(processed['results'][0]['status'], 'SUCCESS');
    });

    test('OAuth-Konto ruft per XOAUTH2 ab', () async {
      final env = await TestEnv.create();
      addTearDown(env.close);
      final mailbox = 'oauth${DateTime.now().millisecondsSinceEpoch}@localhost';
      await _sendMail(mailbox, 'Beleg', 'Anbei', attachmentName: 'beleg.txt', attachment: utf8.encode('Beleg Nummer 42'));
      env.server.db.execute(
        'INSERT INTO mail_accounts (name, imap_server, imap_port, imap_security, username, password, account_type, '
        'refresh_token, expiration) VALUES (?, ?, 3143, 1, ?, ?, 2, ?, ?)',
        ['Gmail', 'localhost', mailbox, 'zugangstoken', 'erneuern', DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String()],
      );
      final account = env.server.db.lastInsertRowId;
      await env.json('POST', '/api/mail_rules/', body: {'name': 'Alles', 'account': account, 'action': 3}, status: 201);
      expect((await env.json('POST', '/api/mail_accounts/$account/process/'))['consumed'], 1);
      await env.server.consumer.idle();
      expect((await env.json('GET', '/api/documents/?query=beleg'))['count'], 1);
    });
  }, skip: _enabled ? false : 'PAPERBUDDY_IT=1 setzen');
}
