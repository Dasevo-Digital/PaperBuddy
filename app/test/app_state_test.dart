import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/documents_controller.dart';
import 'package:paperbuddy/src/upload_queue.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'support.dart';

void main() {
  late TestServer server;

  setUp(() async => server = await TestServer.start());
  tearDown(() => server.stop());

  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  test('Anmelden, Sitzung wiederherstellen, abmelden', () async {
    final state = await newAppState(server);
    await state.restore();
    expect(state.status, SessionStatus.signedOut);

    await expectLater(
      state.login(TestServer.address, TestServer.username, 'falsch'),
      throwsA(isA<ApiException>()),
    );
    await state.login(
      TestServer.address,
      TestServer.username,
      TestServer.password,
    );
    expect(state.status, SessionStatus.signedIn);
    expect(state.store.lastUsername, 'admin');

    // Neuer Start der App: Token kommt aus dem Schlüsselspeicher.
    final restarted = AppState(state.store, httpClient: server.client);
    await restarted.restore();
    expect(restarted.status, SessionStatus.signedIn);
    expect(restarted.client.user.username, 'admin');

    await restarted.logout();
    expect(restarted.status, SessionStatus.signedOut);
    expect(await restarted.hasSavedSession, isFalse);
  });

  test('Upload-Warteschlange und Dokumentliste mit Filtern', () async {
    final state = await newAppState(server);
    await state.login(
      TestServer.address,
      TestServer.username,
      TestServer.password,
    );
    final client = state.client;
    final inbox = await client.createTag('Posteingang', isInboxTag: true);
    await client.createCorrespondent('Versicherung');
    await state.refreshLabels();
    expect(state.tags[inbox.id]?.name, 'Posteingang');

    var changed = 0;
    state.documentsChanged.addListener(() => changed++);
    await state.uploads.add(client, [
      UploadRequest('police.txt', text('Versicherungspolice vom 01.02.2026')),
      UploadRequest('rechnung.txt', text('Rechnung Handwerker 03.03.2026'), title: 'Handwerker'),
      UploadRequest('doppelt.txt', text('Rechnung Handwerker 03.03.2026')),
    ]);
    expect(
      [for (final j in state.uploads.jobs) j.state],
      [UploadState.done, UploadState.done, UploadState.failed],
    );
    expect(
      state.uploads.jobs.last.message,
      'Dieses Dokument ist bereits vorhanden.',
    );
    expect(changed, 2);

    final docs = DocumentsController(client);
    await docs.refresh();
    expect(docs.total, 2);
    expect(
      docs.items.first.title,
      'Handwerker',
      reason: 'neuestes Belegdatum zuerst, Titel aus dem Upload',
    );

    await docs.setFilter(const DocumentFilter(query: 'versicherung'));
    expect(docs.items.single.title, 'police');

    await docs.setFilter(const DocumentFilter(inboxOnly: true));
    expect(docs.total, 2);
    await client.updateDocument(docs.items.first.id, {'tags': <int>[]});
    await docs.refresh();
    expect(docs.total, 1);
  });

  test('Seitenweises Laden', () async {
    final state = await newAppState(server);
    await state.login(
      TestServer.address,
      TestServer.username,
      TestServer.password,
    );
    // Direkt über den Server anlegen; über die API wartet jeder Upload auf seinen Task.
    for (var i = 0; i < DocumentsController.pageSize + 5; i++) {
      final file = File('${server.dir.path}/dok$i.txt')
        ..writeAsStringSync('Dokument Nummer $i');
      await server.server.consumer.waitFor(
        await server.server.consumer.submit(file, originalName: 'dok$i.txt'),
      );
    }
    final docs = DocumentsController(state.client);
    await docs.refresh();
    expect(docs.items.length, DocumentsController.pageSize);
    expect(docs.hasMore, isTrue);
    await docs.loadMore();
    expect(docs.items.length, DocumentsController.pageSize + 5);
    expect(docs.hasMore, isFalse);
  });
}
