import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/ai/embedder.dart';
import 'package:paperbuddy_server/src/ai/onnx.dart';
import 'package:test/test.dart';

import 'ai_support.dart';

void main() {
  final dir = '${aiCache.models}/multilingual-e5-small';
  final available = File(aiCache.runtime).existsSync() && File('$dir/model_quantized.onnx').existsSync();
  late OnnxRuntime runtime;
  late E5Embedder embedder;

  setUpAll(() async {
    if (!available) return;
    runtime = await OnnxRuntime.start(aiCache.runtime);
    embedder = await E5Embedder.open(
      runtime,
      modelPath: '$dir/model_quantized.onnx',
      tokenizerPath: '$dir/tokenizer.json',
      model: 'test',
      threads: 2,
    );
  });
  tearDownAll(() async {
    if (!available) return;
    await embedder.close();
    runtime.close();
  });

  final skip = available ? false : 'ONNX Runtime oder Modell fehlt (server/tool/fetch_ai.sh)';

  // Die Referenz stammt aus onnxruntime 1.19 (Python). Das quantisierte
  // Modell rechnet je nach Fassung und Prozessor leicht anders (Kosinus
  // zur Referenz 0,997); mit dem fp32-Modell stimmen beide auf 1e-7 überein.
  test('rechnet wie die Referenz (Python, onnxruntime)', skip: skip, () async {
    final ref = jsonDecode(File('test/fixtures/e5_vectors.json').readAsStringSync()) as List;
    final q = await embedder.query('Stromrechnung der Stadtwerke');
    final strom = (await embedder.passages('', (ref[1]['text'] as String).substring(9))).single.vector;
    final arzt = (await embedder.passages('', (ref[2]['text'] as String).substring(9))).single.vector;
    for (final (v, r) in [(q, ref[0]), (strom, ref[1]), (arzt, ref[2])]) {
      for (var i = 0; i < 8; i++) {
        expect(v[i], closeTo(r['head'][i] as num, 0.015), reason: '${r['text']} [$i]');
      }
    }
    expect(dot(q, strom), closeTo(ref[3]['cos01'] as num, 0.01));
    expect(dot(q, arzt), closeTo(ref[3]['cos02'] as num, 0.01));
    expect(dot(q, strom), greaterThan(dot(q, arzt)));
  });

  test('teilt lange Dokumente in Abschnitte an Wortgrenzen', skip: skip, () async {
    final content = List.generate(900, (i) => 'Wort$i').join(' ');
    final passages = await embedder.passages('Langer Vertrag', content);
    expect(passages.length, greaterThan(1));
    expect(passages.first.start, 0);
    expect(content.substring(passages[1].start).startsWith('Wort'), isTrue);
    expect(passages.last.end, lessThanOrEqualTo(content.length));
    for (final p in passages) {
      expect(dot(p.vector, p.vector), closeTo(1, 1e-4));
    }
  });

  test('AiService mit echtem Modell: bereit, einlesen, suchen', skip: skip, () async {
    final db = openInMemoryDatabase();
    final ai = AiService(
      db: db,
      settings: AiSettings(enabled: true, modelsDir: aiCache.models, runtime: aiCache.runtime, threads: 2),
    )..start();
    for (var i = 0; i < 100 && !ai.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ai.state, AiState.ready, reason: '${ai.error}');
    final texts = [
      'Stadtwerke Musterstadt, Jahresabrechnung Strom: Verbrauch 2.345 kWh, neuer Abschlag 78 EUR.',
      'Praxis Dr. Weber, Laborbefund: Die Blutwerte liegen im Normbereich.',
      'Mietvertrag über die Wohnung Lindenstraße 12, Kaltmiete 780 EUR, Kaution drei Monatsmieten.',
    ];
    for (final (i, text) in texts.indexed) {
      db.execute(
        "INSERT INTO documents (id, title, content, created, modified, added, original_filename, mime_type, "
        "checksum, original_path) VALUES (?, '', ?, '2026-01-01', 'x', 'x', 'a.txt', 'text/plain', ?, '')",
        [i + 1, text, 'c$i'],
      );
    }
    await ai.indexPending();
    expect(ai.index.count, 3);
    final hits = ai.search((await ai.query('Wie viel Strom haben wir verbraucht?'))!, [1, 2, 3]);
    expect(hits.first.id, 1);
    expect(ai.search((await ai.query('Blutuntersuchung beim Arzt'))!, [1, 2, 3]).first.id, 2);
    expect(ai.search((await ai.query('rent for the flat'))!, [1, 2, 3]).first.id, 3, reason: 'auch englisch');
    expect(ai.status(detailed: true)['runtime'], startsWith('1.'));
    await ai.close();
    db.close();
  });
}
