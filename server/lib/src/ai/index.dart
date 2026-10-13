import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../db.dart';
import 'embedder.dart';

/// Die Vektoren eines Dokuments: je Abschnitt einer, dazu ihr Mittel.
class DocVectors {
  DocVectors(this.chunks, this.spans, this.dimensions) : mean = Float32List(dimensions) {
    for (var c = 0; c < spans.length; c++) {
      for (var d = 0; d < dimensions; d++) {
        mean[d] += chunks[c * dimensions + d];
      }
    }
    normalize(mean);
  }

  factory DocVectors.of(List<Passage> passages) {
    final dimensions = passages.isEmpty ? 0 : passages.first.vector.length;
    final chunks = Float32List(passages.length * dimensions);
    for (var i = 0; i < passages.length; i++) {
      chunks.setAll(i * dimensions, passages[i].vector);
    }
    return DocVectors(chunks, [for (final p in passages) (p.start, p.end)], dimensions);
  }

  /// Alle Abschnittsvektoren hintereinander.
  final Float32List chunks;

  /// Start und Ende jedes Abschnitts im Inhalt.
  final List<(int, int)> spans;
  final int dimensions;
  final Float32List mean;

  /// Bester Abschnitt für [query]: (Ähnlichkeit, Nummer).
  (double, int) best(Float32List query) {
    var score = -2.0, index = 0;
    for (var c = 0; c < spans.length; c++) {
      final s = dot(query, chunks, c * dimensions);
      if (s > score) {
        score = s;
        index = c;
      }
    }
    return (score, index);
  }
}

/// Vektoren in der Datenbank (`document_embeddings`) mit Zwischenspeicher.
///
/// Ein Trigger löscht die Zeile, sobald sich Titel oder Inhalt ändern; der
/// Zwischenspeicher gleicht vor jeder Abfrage mit der Tabelle ab und merkt
/// so jede Änderung, egal auf welchem Weg sie kam.
class VectorIndex {
  VectorIndex(this.db);
  final Database db;
  final _cache = <int, (String, DocVectors)>{};
  String? _model;

  /// Gilt für das Modell [model]; Vektoren anderer Modelle werden gelöscht.
  void useModel(String model) {
    if (_model == model) return;
    _model = model;
    _cache.clear();
    db.execute('DELETE FROM document_embeddings WHERE model != ?', [model]);
  }

  void store(int documentId, List<Passage> passages, int dimensions) {
    final model = _model ?? (throw StateError('Kein Modell gewählt'));
    final chunks = Float32List(passages.length * dimensions);
    for (var i = 0; i < passages.length; i++) {
      chunks.setAll(i * dimensions, passages[i].vector);
    }
    db.execute(
      'INSERT OR REPLACE INTO document_embeddings (document_id, model, dimensions, chunks, spans, updated) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        documentId,
        model,
        dimensions,
        chunks.buffer.asUint8List(),
        jsonEncode([for (final p in passages) [p.start, p.end]]),
        nowIso(),
      ],
    );
  }

  /// Gleicht den Zwischenspeicher mit der Tabelle ab und liefert ihn.
  Map<int, DocVectors> all() {
    final model = _model;
    if (model == null) return const {};
    final current = {
      for (final r in db.select('SELECT document_id, updated FROM document_embeddings WHERE model = ?', [model]))
        r['document_id'] as int: r['updated'] as String,
    };
    _cache.removeWhere((id, v) => current[id] != v.$1);
    final load = [for (final e in current.entries) if (!_cache.containsKey(e.key)) e.key];
    for (var i = 0; i < load.length; i += 500) {
      final ids = load.skip(i).take(500).toList();
      for (final r in db.select(
        'SELECT document_id, dimensions, chunks, spans, updated FROM document_embeddings '
        'WHERE document_id IN (${List.filled(ids.length, '?').join(',')})',
        ids,
      )) {
        final blob = r['chunks'] as Uint8List;
        _cache[r['document_id'] as int] = (
          r['updated'] as String,
          DocVectors(
            Float32List.fromList(blob.buffer.asFloat32List(blob.offsetInBytes, blob.lengthInBytes ~/ 4)),
            [for (final s in jsonDecode(r['spans'] as String) as List) ((s as List)[0] as int, s[1] as int)],
            r['dimensions'] as int,
          ),
        );
      }
    }
    return {for (final e in _cache.entries) e.key: e.value.$2};
  }

  DocVectors? of(int documentId) => all()[documentId];

  /// Dokumente ohne Vektoren, neueste zuerst.
  List<int> missing({int limit = 20}) => [
        for (final r in db.select(
          'SELECT d.id FROM documents d LEFT JOIN document_embeddings e ON e.document_id = d.id '
          'WHERE d.deleted_at IS NULL AND e.document_id IS NULL ORDER BY d.id DESC LIMIT ?',
          [limit],
        ))
          r['id'] as int,
      ];

  int get count => _model == null
      ? 0
      : db.select(
          'SELECT COUNT(*) AS c FROM document_embeddings e JOIN documents d ON d.id = e.document_id '
          'WHERE e.model = ? AND d.deleted_at IS NULL',
          [_model],
        ).first['c'] as int;
}
