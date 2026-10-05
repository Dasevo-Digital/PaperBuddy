import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PaperbuddyServer server;
  late HttpServer http;
  late PaperlessClient client;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-api-backlog-');
    server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': tmp.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
        'PAPERBUDDY_OAUTH_CALLBACK_BASE_URL': 'https://docs.example.org',
        'PAPERBUDDY_GMAIL_OAUTH_CLIENT_ID': 'client',
        'PAPERBUDDY_GMAIL_OAUTH_CLIENT_SECRET': 'secret',
      }),
      database: openInMemoryDatabase(),
    );
    http = await io.serve(server.handler, 'localhost', 0);
    client = await PaperlessClient.login('localhost:${http.port}', 'admin', 'geheim123');
  });

  tearDown(() async {
    client.close();
    await http.close(force: true);
    server.workflows.stop();
    server.db.close();
    await tmp.delete(recursive: true);
  });

  test('Client bleibt bei API v9, auch wenn der Server v10 kann', () {
    expect(client.apiVersion, 9);
  });

  test('Versionen und Verlauf', () async {
    final task = await client.waitForTask(await client.uploadDocument(utf8.encode('Erste Fassung'), 'brief.txt'),
        interval: const Duration(milliseconds: 50));
    final id = task.documentId!;
    final vTask = await client.waitForTask(
        await client.uploadVersion(id, utf8.encode('Zweite Fassung'), 'brief-v2.txt', label: 'korrigiert'),
        interval: const Duration(milliseconds: 50));
    expect(vTask.status, TaskStatus.success, reason: vTask.result);
    final doc = await client.document(id);
    expect(doc.versions.map((v) => v.label), [null, 'korrigiert']);
    expect(doc.versions.first.isRoot, isTrue);
    expect(utf8.decode((await client.downloadFile(id)).bytes), 'Zweite Fassung');
    expect(utf8.decode((await client.downloadFile(id, version: doc.versions.first.id)).bytes), 'Erste Fassung');

    await client.updateDocument(id, {'title': 'Brief an Amt'});
    final history = await client.history(id);
    expect(history.first.changes['title'], ['brief', 'Brief an Amt']);
    expect(history.first.actor, 'admin');
    expect(history.last.action, 'create');

    await client.deleteVersion(id, doc.versions.first.id);
    expect((await client.document(id)).versions, hasLength(1));
  });

  test('OAuth-Links für Mailkonten', () async {
    final urls = await client.mailOAuthUrls();
    expect(urls.gmail, startsWith('https://accounts.google.com/'));
    expect(Uri.parse(urls.gmail!).queryParameters['redirect_uri'], 'https://docs.example.org/api/oauth/callback/');
    expect(urls.outlook, isNull);
  });
}
