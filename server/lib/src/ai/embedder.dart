import 'dart:math';
import 'dart:typed_data';

import 'onnx.dart';
import 'tokenizer.dart';

/// Ein Abschnitt eines Dokuments mit seinem Vektor; [start] und [end] sind
/// Zeichenpositionen im Inhalt.
class Passage {
  Passage(this.vector, this.start, this.end);
  final Float32List vector;
  final int start;
  final int end;
}

/// Macht aus Text normierte Vektoren, deren Skalarprodukt die inhaltliche
/// Nähe misst.
abstract interface class TextEmbedder {
  /// Kennung des Modells; ändert sie sich, wird alles neu berechnet.
  String get model;
  int get dimensions;

  /// Vektor einer Suchanfrage.
  Future<Float32List> query(String text);

  /// Vektoren eines Dokuments, in Abschnitten von Modelllänge.
  Future<List<Passage>> passages(String title, String content);

  Future<void> close();
}

/// multilingual-e5-small: Anfragen beginnen mit „query: “, Dokumente mit
/// „passage: “; der Vektor ist der Mittelwert der Ausgaben aller Tokens.
class E5Embedder implements TextEmbedder {
  E5Embedder._(this._session, this._tokenizer, this.model, this.maxChunks);

  final OnnxSession _session;
  final UnigramTokenizer _tokenizer;
  @override
  final String model;

  /// So viele Abschnitte je Dokument (je bis zu 512 Tokens, rund eine
  /// Seite); spätere Seiten gehen nicht in die Suche ein.
  final int maxChunks;

  static const _maxLength = 512;
  /// Abschnitte je Rechnung; mehr spart kaum Zeit, kostet aber Speicher
  /// (bei 512 Tokens rund 25 MB je Abschnitt).
  static const _batch = 2;

  static Future<E5Embedder> open(
    OnnxRuntime runtime, {
    required String modelPath,
    required String tokenizerPath,
    required String model,
    int threads = 0,
    int maxChunks = 24,
  }) async {
    final tokenizer = await UnigramTokenizer.load(tokenizerPath);
    final session = await runtime.open(modelPath, threads: threads);
    if (!session.outputs.contains('last_hidden_state')) {
      await session.close();
      throw StateError('Modell ohne last_hidden_state: ${session.outputs}');
    }
    return E5Embedder._(session, tokenizer, model, maxChunks);
  }

  @override
  int get dimensions => 384;

  @override
  Future<Float32List> query(String text) async =>
      (await _embed([_tokenizer.encode('query: ${text.trim()}', maxLength: _maxLength)])).single;

  @override
  Future<List<Passage>> passages(String title, String content) async {
    final prefix = _tokenizer.tokenize('passage:');
    final heading = _tokenizer.tokenize(title.trim());
    if (heading.length > 32) heading.length = 32;
    final room = _maxLength - 2 - prefix.length;
    final chunks = <(List<int>, int, int)>[];
    var ids = <int>[...heading];
    var start = -1, end = 0;
    for (final m in RegExp(r'\S+').allMatches(content)) {
      var word = _tokenizer.tokenize(m.group(0)!);
      if (word.isEmpty) continue;
      if (word.length > room) word = word.sublist(0, room);
      if (ids.length + word.length > room && start >= 0) {
        chunks.add((ids, start, end));
        if (chunks.length >= maxChunks) break;
        ids = [];
        start = -1;
      }
      if (start < 0) start = m.start;
      ids.addAll(word);
      end = m.end;
    }
    if (start >= 0 && chunks.length < maxChunks) chunks.add((ids, start, end));
    // Nur ein Titel, kein Text: trotzdem auffindbar.
    if (chunks.isEmpty && heading.isNotEmpty) chunks.add((heading, 0, 0));
    final vectors = <Float32List>[];
    for (var i = 0; i < chunks.length; i += _batch) {
      final batch = chunks.skip(i).take(_batch);
      vectors.addAll(await _embed([
        for (final c in batch) [UnigramTokenizer.bosId, ...prefix, ...c.$1, UnigramTokenizer.eosId],
      ]));
    }
    return [for (var i = 0; i < chunks.length; i++) Passage(vectors[i], chunks[i].$2, chunks[i].$3)];
  }

  /// Rechnet einen Stapel gleich lang aufgefüllter Eingaben und mittelt je
  /// Eingabe über die echten Tokens.
  Future<List<Float32List>> _embed(List<List<int>> inputs) async {
    final rows = inputs.length;
    final length = inputs.map((i) => i.length).reduce(max);
    final ids = Int64List(rows * length)..fillRange(0, rows * length, UnigramTokenizer.padId);
    final mask = Int64List(rows * length);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < inputs[r].length; c++) {
        ids[r * length + c] = inputs[r][c];
        mask[r * length + c] = 1;
      }
    }
    final shape = [rows, length];
    final (out, outShape) = await _session.run({
      'input_ids': (ids, shape),
      'attention_mask': (mask, shape),
      if (_session.inputs.contains('token_type_ids')) 'token_type_ids': (Int64List(rows * length), shape),
    }, 'last_hidden_state');
    final dim = outShape[2];
    return [
      for (var r = 0; r < rows; r++)
        () {
          final v = Float32List(dim);
          final n = inputs[r].length;
          for (var t = 0; t < n; t++) {
            final base = (r * length + t) * dim;
            for (var d = 0; d < dim; d++) {
              v[d] += out[base + d];
            }
          }
          return normalize(v);
        }(),
    ];
  }

  @override
  Future<void> close() => _session.close();
}

/// Bringt [v] auf Länge 1 (in place).
Float32List normalize(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = sqrt(sum);
  if (norm > 0) {
    for (var i = 0; i < v.length; i++) {
      v[i] /= norm;
    }
  }
  return v;
}

/// Skalarprodukt von [a] mit dem Vektor ab [offset] in [b].
double dot(Float32List a, Float32List b, [int offset = 0]) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[offset + i];
  }
  return s;
}
