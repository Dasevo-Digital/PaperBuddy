import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Testet den Client gegen den echten Server im selben Prozess.
void main() {
  late Directory tmp;
  late PaperbuddyServer server;
  late HttpServer http;
  late String address;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('paperbuddy-api-test-');
    server = await PaperbuddyServer.create(
      Config.fromEnvironment({
        'PAPERBUDDY_DATA_DIR': tmp.path,
        'PAPERBUDDY_ADMIN_USER': 'admin',
        'PAPERBUDDY_ADMIN_PASSWORD': 'geheim123',
      }),
      database: openInMemoryDatabase(),
    );
    http = await io.serve(server.handler, 'localhost', 0);
    address = 'localhost:${http.port}/';
  });

  tearDownAll(() async {
    await http.close(force: true);
    server.db.close();
    await tmp.delete(recursive: true);
  });

  test('Adressen werden normalisiert', () {
    expect(
      PaperlessClient.normalizeBaseUrl('nas:8000/').toString(),
      'http://nas:8000',
    );
    expect(
      PaperlessClient.normalizeBaseUrl(
        'https://docs.example.org/paperless/api/',
      ).toString(),
      'https://docs.example.org/paperless',
    );
    expect(
      () => PaperlessClient.normalizeBaseUrl(' '),
      throwsA(isA<ApiException>()),
    );
  });

  test('Falsches Passwort und ungültiger Token', () async {
    await expectLater(
      PaperlessClient.login(address, 'admin', 'falsch'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      PaperlessClient.connect(address, 'kaputt'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.isUnauthorized,
          'unauthorized',
          isTrue,
        ),
      ),
    );
  });

  test('Anmelden, hochladen, filtern, bearbeiten, löschen', () async {
    final client = await PaperlessClient.login(address, 'admin', 'geheim123');
    expect(client.apiVersion, 9);
    expect(client.user.username, 'admin');
    expect(client.user.can('add', 'document'), isTrue);

    final again = await PaperlessClient.connect(address, client.token);
    expect(again.user.id, client.user.id);

    final inbox = await client.createTag('Posteingang', isInboxTag: true);
    final steuer = await client.createTag('Steuer', color: '#ff0000');
    final amt = await client.createCorrespondent('Finanzamt');
    final bescheid = await client.createDocumentType('Bescheid');
    await expectLater(
      client.createTag('Steuer'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.fieldErrors.keys,
          'fields',
          contains('name'),
        ),
      ),
    );

    final taskId = await client.uploadDocument(
      utf8.encode('Einkommensteuerbescheid für 2025 vom 12.05.2026'),
      'bescheid.txt',
      title: 'Steuerbescheid 2025',
      correspondent: amt.id,
      documentType: bescheid.id,
      tags: [steuer.id],
    );
    final task = await client.waitForTask(
      taskId,
      interval: const Duration(milliseconds: 50),
    );
    expect(task.status, TaskStatus.success, reason: task.result);

    final doc = await client.document(task.documentId!);
    expect(doc.title, 'Steuerbescheid 2025');
    expect(doc.created, DateTime(2026, 5, 12));
    expect(doc.tags, unorderedEquals([steuer.id, inbox.id]));
    expect(doc.correspondent, amt.id);

    final tags = await client.tags();
    expect(tags.firstWhere((t) => t.id == steuer.id).documentCount, 1);
    expect(tags.firstWhere((t) => t.id == steuer.id).textColor, '#ffffff');

    var page = await client.documents(
      filter: const DocumentFilter(query: 'einkommen'),
    );
    expect(page.count, 1);
    expect(page.results.single.searchHit?.highlights, contains('match'));

    page = await client.documents(
      filter: DocumentFilter(inboxOnly: true, documentTypes: {bescheid.id}),
    );
    expect(page.allIds, [doc.id]);
    page = await client.documents(
      filter: DocumentFilter(createdFrom: DateTime(2026, 6, 1)),
    );
    expect(page.count, 0);

    final updated = await client.updateDocument(doc.id, {
      'title': 'Bescheid ESt 2025',
      'tags': [steuer.id],
    });
    expect(updated.title, 'Bescheid ESt 2025');
    expect(updated.tags, [steuer.id]);

    final notes = await client.addNote(doc.id, 'Einspruchsfrist beachten');
    expect(notes.single.username, 'admin');

    expect(
      utf8.decode(await client.download(doc.id)),
      contains('Einkommensteuerbescheid'),
    );
    expect(
      await client.autocomplete('einkom'),
      contains('einkommensteuerbescheid'),
    );

    await client.deleteDocument(doc.id);
    await expectLater(
      client.document(doc.id),
      throwsA(
        isA<ApiException>().having((e) => e.isNotFound, 'notFound', isTrue),
      ),
    );
    client.close();
  });

  test('Nicht erreichbarer Server', () async {
    await expectLater(
      PaperlessClient.login('localhost:1', 'a', 'b'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('nicht erreichbar'),
        ),
      ),
    );
  });
}
