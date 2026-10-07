import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperbuddy/src/app_state.dart';
import 'package:paperbuddy/src/file_cache.dart';
import 'package:paperbuddy/src/session_store.dart';
import 'package:paperbuddy/src/upload_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  late TestServer server;
  late Directory base;

  setUp(() async {
    server = await TestServer.start();
    base = await Directory.systemTemp.createTemp('paperbuddy-cache-test-');
    FileCache.testBase = base;
  });
  tearDown(() async {
    FileCache.testBase = null;
    await base.delete(recursive: true);
    await server.stop();
  });

  test('Dokumente und Vorschauen auf dem Gerät, offline lesen', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var down = false;
    var requests = 0;
    final store = SessionStore(await SharedPreferences.getInstance());
    // Wie TestServer.client, aber abschaltbar und mit Zähler.
    http.Client client() => MockClient.streaming((request, body) async {
      if (down) throw http.ClientException('Netzwerk weg', request.url);
      requests++;
      return server.client().send(
        http.StreamedRequest(request.method, request.url)
          ..headers.addAll(request.headers)
          ..sink.add(await body.toBytes())
          ..sink.close(),
      );
    });
    final state = AppState(store, httpClient: client);
    await state.login(
      TestServer.address,
      TestServer.username,
      TestServer.password,
    );
    expect(state.files, isNotNull);

    await state.uploads.add(state.client, [
      UploadRequest(
        'vertrag.txt',
        Uint8List.fromList(utf8.encode('Mietvertrag Wohnung 01.04.2025')),
      ),
    ]);
    final doc = (await state.client.documents()).results.single;

    // Zweites Öffnen kommt aus dem Speicher, ohne Anfrage.
    final first = await state.download(doc);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = requests;
    final again = await state.download(doc);
    expect(again.bytes, first.bytes);
    expect(requests, before);

    // Vorschau: nach „Neustart“ (leerer Arbeitsspeicher) vom Gerät.
    final png = Uint8List.fromList([1, 2, 3]);
    await state.files!.storeThumbnail(doc.id, doc.modified, png);
    state.thumbnails.clear();
    final beforeThumb = requests;
    expect(
      await state.thumbnails.get(state.client, doc.id, modified: doc.modified),
      png,
    );
    expect(requests, beforeThumb);
    // Neue Fassung des Dokuments: alte Vorschau gilt nicht mehr.
    expect(await state.files!.thumbnail(doc.id, DateTime(2030)), isNull);

    // Offline markieren, Server weg: Liste und Datei gibt es trotzdem.
    await state.keepOffline(doc);
    down = true;
    final offline = await state.files!.offlineDocuments();
    expect(offline[doc.id]?.title, doc.title);
    final file = await state.files!.document(
      doc.id,
      original: false,
      anyVersion: true,
    );
    expect(utf8.decode(file!.bytes), contains('Mietvertrag'));

    // „Leeren“ lässt Offline-Dokumente stehen.
    await state.files!.clearTemporary();
    expect(await state.files!.isOffline(doc.id), isTrue);

    // Ohne Anmeldung findet die App den Speicher über den letzten Server.
    final restarted = AppState(store, httpClient: client);
    final cache = await restarted.offlineCache();
    expect((await cache!.offlineDocuments()).keys, [doc.id]);

    // Abmelden entfernt alles vom Gerät.
    down = false;
    await state.logout();
    expect(await cache.offlineDocuments(), isEmpty);
    state.notifications.stop();
  });
}
