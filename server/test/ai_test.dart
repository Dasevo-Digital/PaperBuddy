import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/ai/embedder.dart';
import 'package:paperbuddy_server/src/ai/index.dart';
import 'package:paperbuddy_server/src/processing/classifier.dart';
import 'package:test/test.dart';

import 'ai_support.dart';
import 'helpers.dart';

const _strom = 'Stadtwerke Musterstadt Jahresabrechnung Strom Verbrauch Kilowattstunden Abschlag Zählernummer';
const _arzt = 'Praxis Weber Befundbericht Blutwerte Laborbefund Cholesterin Kontrolle Normbereich';
const _miete = 'Hausverwaltung Mietvertrag Wohnung Kaltmiete Kaution Nebenkosten Vermieter';

void main() {
  group('mit lokaler KI', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create(ai: true));
    tearDown(() => env.close());

    test('semantische Suche: bester Abschnitt, Rechte und Filter', () async {
      final strom = (await env.uploadText('strom.txt', _strom))!;
      final arzt = (await env.uploadText('arzt.txt', _arzt))!;
      await env.uploadText('miete.txt', _miete);
      expect(env.server.ai.index.count, 3, reason: 'Vektoren schon beim Verarbeiten');

      final r = await env.json('GET', '/api/documents/?semantic_query=Strom%20Verbrauch%20Abschlag');
      expect(r['results'].first['id'], strom);
      final hit = r['results'].first['__search_hit__'];
      expect(hit['rank'], 0);
      expect(hit['highlights'], startsWith('Stadtwerke'));
      expect(r['all'], isNot(contains(arzt)), reason: 'nur, was nah am besten Treffer liegt');

      // Filter und Rechte gelten wie bei der Volltextsuche.
      final filtered = await env.json('GET', '/api/documents/?semantic_query=Strom&id__in=$arzt');
      expect([for (final d in filtered['results']) d['id']], [arzt]);
      env.server.db.execute('UPDATE documents SET owner = (SELECT id FROM users WHERE username = ?)', ['admin']);
      env.addUser('bob', permissions: ['view_document']);
      expect((await env.json('GET', '/api/documents/?semantic_query=Strom', as: 'bob'))['count'], 0);
    });

    test('geänderter Inhalt wird neu eingelesen', () async {
      final id = (await env.uploadText('a.txt', _strom))!;
      final before = env.server.ai.vectorOf(id)!;
      await env.json('PATCH', '/api/documents/$id/', body: {'content': _arzt});
      expect(env.server.ai.vectorOf(id), isNull, reason: 'Trigger löscht veraltete Vektoren');
      await env.server.ai.indexPending();
      final after = env.server.ai.vectorOf(id)!;
      expect(dot(before, after), lessThan(0.9));
      final r = await env.json('GET', '/api/documents/?semantic_query=Blutwerte%20Labor');
      expect(r['results'].first['id'], id);
    });

    test('ähnliche Dokumente (more_like_id) über Vektoren', () async {
      final a = (await env.uploadText('a.txt', '$_strom Nachzahlung'))!;
      final b = (await env.uploadText('b.txt', '$_strom Guthaben'))!;
      await env.uploadText('c.txt', _arzt);
      final r = await env.json('GET', '/api/documents/?more_like_id=$a');
      expect(r['results'].first['id'], b);
      expect(r['all'], isNot(contains(a)));
    });

    test('Zuordnung über die ähnlichsten Dokumente', () async {
      final werke = (await env.json('POST', '/api/correspondents/', status: 201, body: {'name': 'Stadtwerke', 'matching_algorithm': 6}))['id'];
      final praxis = (await env.json('POST', '/api/correspondents/', status: 201, body: {'name': 'Praxis', 'matching_algorithm': 6}))['id'];
      for (var i = 0; i < 3; i++) {
        await env.uploadText('s$i.txt', '$_strom Rechnung $i', fields: {'correspondent': werke});
        await env.uploadText('p$i.txt', '$_arzt Termin $i', fields: {'correspondent': praxis});
      }
      final id = (await env.uploadText('neu.txt', 'Jahresabrechnung Strom mit Abschlag und Zählernummer'))!;
      final doc = await env.json('GET', '/api/documents/$id/');
      expect(doc['correspondent'], werke);
      final s = await env.json('GET', '/api/documents/$id/suggestions/');
      expect(s['correspondents'], [werke]);
    });

    test('Status: Zustand für alle, Fortschritt für Administratoren', () async {
      await env.uploadText('a.txt', _strom);
      final admin = await env.json('GET', '/api/ai/');
      expect(admin['state'], 'ready');
      expect(admin['indexed'], 1);
      expect(admin['total'], 1);
      env.addUser('bob', permissions: ['view_document']);
      final bob = await env.json('GET', '/api/ai/', as: 'bob');
      expect(bob['state'], 'ready');
      expect(bob.containsKey('indexed'), isFalse);
      final health = await env.call('GET', '/api/health/');
      expect(await health.readAsString(), contains('"ai":"ready"'));
    });
  });

  group('ohne lokale KI', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    test('semantische Suche abgelehnt, Status aus', () async {
      await env.json('GET', '/api/documents/?semantic_query=Strom', status: 400);
      expect((await env.json('GET', '/api/ai/'))['state'], 'disabled');
    });

    test('ähnliche Dokumente über Wortgewichte', () async {
      final a = (await env.uploadText('a.txt', '$_strom Nachzahlung'))!;
      final b = (await env.uploadText('b.txt', '$_strom Guthaben'))!;
      await env.uploadText('c.txt', _arzt);
      final r = await env.json('GET', '/api/documents/?more_like_id=$a');
      expect([for (final d in r['results']) d['id']], [b]);
    });

    test('eingeschaltet, aber ohne ONNX Runtime: Hinweis statt Absturz', () async {
      final ai = AiService(
        db: env.server.db,
        settings: const AiSettings(enabled: true, runtime: '/gibt/es/nicht/libonnxruntime.so'),
      )..start();
      expect(ai.state, AiState.unavailable);
      expect(ai.status(detailed: true)['error'], contains('nicht gefunden'));
      await ai.close();
    });
  });

  test('Modell wird nach der Ruhezeit freigegeben, leere Durchgänge verschieben das nicht', () async {
    final db = openInMemoryDatabase();
    final embedder = FakeEmbedder();
    final ai = AiService.withEmbedder(db, embedder, idle: const Duration(milliseconds: 150));
    await ai.query('Strom');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await ai.indexPending(); // nichts zu tun, wie der Durchgang jede Minute
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(embedder.closed, 1);
    await ai.query('wieder da');
    expect(embedder.calls, 2);
    await ai.close();
    db.close();
  });

  test('Klassifikator: Vektoren entscheiden, wo Wörter nicht helfen', () {
    final db = openInMemoryDatabase();
    db.execute("INSERT INTO correspondents (id, name) VALUES (1, 'A'), (2, 'B')");
    // B hat mehr Dokumente; ohne gemeinsame Wörter entscheidet Naive Bayes
    // nach Häufigkeit für B.
    final texts = {1: 'alpha beta', 2: 'alpha beta', 3: 'gamma delta', 4: 'gamma delta', 5: 'gamma delta'};
    for (final e in texts.entries) {
      db.execute(
        "INSERT INTO documents (id, title, content, correspondent_id, created, modified, added, original_filename, "
        "mime_type, checksum, original_path) VALUES (?, '', ?, ?, '2026-01-01', 'x', 'x', 'a.txt', 'text/plain', ?, '')",
        [e.key, e.value, e.key <= 2 ? 1 : 2, 'c${e.key}'],
      );
    }
    final classifier = DocumentClassifier(db)..trainIfNeeded();
    Float32List unit(int axis) => Float32List(8)..[axis] = 1;
    DocVectors doc(int axis) => DocVectors(unit(axis), [(0, 1)], 8);
    final vectors = {1: doc(0), 2: doc(0), 3: doc(1), 4: doc(1), 5: doc(1)};
    expect(classifier.predict('epsilon').correspondent, 2);
    expect(classifier.predict('epsilon', vector: unit(0), vectors: vectors).correspondent, 1);
    expect(classifier.similar(1, [2, 3, 4], vectors: vectors).first.$1, 2);
    db.close();
  });

  group('Modelle laden', () {
    late HttpServer http;
    late Directory dir;
    final payload = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('paperbuddy-models-');
      http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((r) {
        r.response.add(payload);
        r.response.close();
      });
    });
    tearDown(() async {
      await http.close(force: true);
      await dir.delete(recursive: true);
    });

    ModelSpec spec(String sha) => ModelSpec(
          id: 'probe',
          source: 'test',
          license: 'test',
          files: [ModelFile('model.onnx', 'http://127.0.0.1:${http.port}/m', sha, payload.length)],
        );

    test('prüft die Prüfsumme und meldet den Fortschritt', () async {
      final store = ModelStore(dir.path);
      final model = spec(sha256.convert(payload).toString());
      expect(store.isInstalled(model), isFalse);
      var last = 0;
      await store.download(model, progress: (done, total) => last = done);
      expect(last, payload.length);
      expect(store.isInstalled(model), isTrue);
      await store.verify(model);
    });

    test('verwirft eine Datei mit falscher Prüfsumme', () async {
      final store = ModelStore(dir.path);
      final model = spec('0' * 64);
      await expectLater(store.download(model), throwsStateError);
      expect(store.isInstalled(model), isFalse);
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });
}
