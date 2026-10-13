import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

import '../ai/embedder.dart';
import '../ai/index.dart';

final _log = Logger('classifier');

/// Lernendes Matching (`matching_algorithm = 6`, „Auto“).
///
/// Paperless-ngx trainiert dafür ein neuronales Netz mit scikit-learn. Hier
/// genügt ein multinomialer Naive-Bayes-Klassifikator auf Wortzählungen: er
/// lernt aus den vorhandenen Zuordnungen, ist in Millisekunden trainiert und
/// braucht keine externen Abhängigkeiten.
///
/// Mit der lokalen KI entscheiden stattdessen die ähnlichsten bereits
/// zugeordneten Dokumente (siehe [predict]). Eine Korrektur wirkt dabei
/// sofort, ohne neues Training.
class DocumentClassifier {
  DocumentClassifier(this.db);
  final Database db;

  _Multiclass? _correspondent;
  _Multiclass? _documentType;
  _Multiclass? _storagePath;
  Map<int, _Binary> _tags = {};
  String? _trainedOn;

  /// Gewichtete Wörter und Zuordnungen je Dokument, für [predict] und
  /// [similar].
  Map<int, _Sample> _samples = {};
  Map<String, int> _df = {};

  bool get isTrained => _trainedOn != null;

  /// Kennzeichen des Datenstands; neu trainiert wird nur bei Änderungen.
  String _fingerprint() {
    final r = db.select(
      "SELECT COUNT(*) AS c, MAX(modified) AS m FROM documents WHERE deleted_at IS NULL",
    ).first;
    final labels = db.select(
      'SELECT (SELECT COUNT(*) FROM tags WHERE matching_algorithm = 6) || \'/\' || '
      '(SELECT COUNT(*) FROM correspondents WHERE matching_algorithm = 6) || \'/\' || '
      '(SELECT COUNT(*) FROM document_types WHERE matching_algorithm = 6) || \'/\' || '
      '(SELECT COUNT(*) FROM storage_paths WHERE matching_algorithm = 6) AS l',
    ).first['l'];
    return '${r['c']}|${r['m']}|$labels';
  }

  /// Trainiert neu, falls sich Dokumente oder Auto-Labels geändert haben.
  void trainIfNeeded() {
    final fp = _fingerprint();
    if (fp == _trainedOn) return;
    final sw = Stopwatch()..start();
    final docs = db.select(
      'SELECT d.id, d.title, d.content, d.correspondent_id, d.document_type_id, d.storage_path_id, '
      '(SELECT group_concat(tag_id) FROM document_tags WHERE document_id = d.id) AS tag_ids '
      'FROM documents d WHERE d.deleted_at IS NULL',
    );
    final tokens = <int, Map<String, int>>{
      for (final d in docs) d['id'] as int: tokenize('${d['title']} ${d['content']}'),
    };

    Set<int> autoIds(String table) => {
          for (final r in db.select('SELECT id FROM $table WHERE matching_algorithm = 6')) r['id'] as int,
        };

    _Multiclass? multi(String table, String column) {
      final auto = autoIds(table);
      if (auto.isEmpty) return null;
      final model = _Multiclass();
      for (final d in docs) {
        final label = d[column] as int?;
        model.add(label != null && auto.contains(label) ? label : 0, tokens[d['id']]!);
      }
      return model.hasClasses ? model : null;
    }

    _correspondent = multi('correspondents', 'correspondent_id');
    _documentType = multi('document_types', 'document_type_id');
    _storagePath = multi('storage_paths', 'storage_path_id');

    final autoTags = autoIds('tags');
    _tags = {};
    for (final tag in autoTags) {
      final model = _Binary();
      for (final d in docs) {
        final ids = (d['tag_ids'] as String?)?.split(',').map(int.parse).toSet() ?? const <int>{};
        model.add(ids.contains(tag), tokens[d['id']]!);
      }
      // Ohne Gegenbeispiele würde jeder Text als Treffer gelten.
      if (model.positives >= 1 && model.negatives >= 1) _tags[tag] = model;
    }
    final autoCorrespondents = autoIds('correspondents');
    final autoTypes = autoIds('document_types');
    final autoPaths = autoIds('storage_paths');
    int auto(Set<int> ids, Object? label) => label is int && ids.contains(label) ? label : 0;
    _df = {};
    _docCount = docs.length;
    for (final words in tokens.values) {
      for (final w in words.keys) {
        _df[w] = (_df[w] ?? 0) + 1;
      }
    }
    _samples = {
      for (final d in docs)
        d['id'] as int: _Sample(
          _tfidf(tokens[d['id']]!),
          auto(autoCorrespondents, d['correspondent_id']),
          auto(autoTypes, d['document_type_id']),
          auto(autoPaths, d['storage_path_id']),
          {
            for (final t in (d['tag_ids'] as String?)?.split(',').map(int.parse) ?? const <int>[])
              if (autoTags.contains(t)) t,
          },
        ),
    };
    _autoTags = autoTags;
    _trainedOn = fp;
    _log.fine('Trainiert auf ${docs.length} Dokumenten in ${sw.elapsedMilliseconds} ms');
  }

  Set<int> _autoTags = {};
  int _docCount = 0;

  /// TF-IDF, auf Länge 1 gebracht.
  Map<String, double> _tfidf(Map<String, int> counts) {
    final total = max(_docCount, 1);
    final v = <String, double>{
      for (final e in counts.entries) e.key: (1 + log(e.value)) * log((total + 1) / ((_df[e.key] ?? 0) + 1)),
    };
    final norm = sqrt(v.values.fold(0.0, (s, x) => s + x * x));
    if (norm > 0) v.updateAll((_, x) => x / norm);
    return v;
  }

  static double _cosine(Map<String, double> a, Map<String, double> b) {
    if (a.length > b.length) (a, b) = (b, a);
    var s = 0.0;
    a.forEach((w, x) {
      final y = b[w];
      if (y != null) s += x * y;
    });
    return s;
  }

  /// Ähnlichkeit zweier Dokumente: Wortgewichte (TF-IDF) und, wenn es sie
  /// gibt, die Vektoren der lokalen KI. multilingual-e5 liefert Werte
  /// zwischen etwa 0,75 und 1; sie werden auf 0–1 gestreckt.
  static double _similarity(Map<String, double> words, Float32List? vector, _Sample s, Float32List? other) {
    final t = _cosine(words, s.words);
    if (vector == null || other == null) return t;
    return _vectorWeight * (dot(vector, other) - 0.75) / 0.25 + (1 - _vectorWeight) * t;
  }

  /// Anteil der Vektoren an der Ähnlichkeit. Gemessen an ausgedachten
  /// Dokumenten (Korrespondenten und Typen, Kreuzvalidierung): 0,3 traf mit
  /// einem einzigen Beispiel je Korrespondent zu 99 % (Naive Bayes 86 %),
  /// reine Vektoren zu 97 %, reine Wortgewichte zu 93 %.
  static const _vectorWeight = 0.3;
  static const _neighbours = 7;

  /// Zuordnung über die [_neighbours] ähnlichsten Dokumente, gewichtet nach
  /// Ähnlichkeit. Ohne [vector] oder mit zu wenigen eingelesenen Dokumenten
  /// entscheidet Naive Bayes.
  Prediction predict(String text, {Float32List? vector, Map<int, DocVectors> vectors = const {}, int? exclude}) {
    final known = vector == null
        ? const <int>[]
        : [for (final id in _samples.keys) if (id != exclude && (vectors[id]?.spans.isNotEmpty ?? false)) id];
    if (known.length < 3) {
      return Prediction(
        correspondent: predictCorrespondent(text),
        documentType: predictDocumentType(text),
        storagePath: predictStoragePath(text),
        tags: predictTags(text),
      );
    }
    final words = _tfidf(tokenize(text));
    final scored = [for (final id in known) (id, _similarity(words, vector, _samples[id]!, vectors[id]!.mean))]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final top = scored.take(_neighbours).toList();
    final best = top.first.$2;
    // Ähnlichere Nachbarn zählen deutlich mehr (Softmax, Temperatur 0,1).
    final weights = [for (final (id, s) in top) (_samples[id]!, exp((s - best) / 0.1))];
    final total = weights.fold(0.0, (s, w) => s + w.$2);
    int? vote(int Function(_Sample) label, bool hasAuto) {
      if (!hasAuto) return null;
      final votes = <int, double>{};
      for (final (s, w) in weights) {
        votes[label(s)] = (votes[label(s)] ?? 0) + w;
      }
      final winner = votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
      return winner == 0 ? null : winner;
    }

    return Prediction(
      correspondent: vote((s) => s.correspondent, _correspondent != null),
      documentType: vote((s) => s.documentType, _documentType != null),
      storagePath: vote((s) => s.storagePath, _storagePath != null),
      tags: {
        for (final tag in _autoTags)
          if (weights.where((w) => w.$1.tags.contains(tag)).fold(0.0, (s, w) => s + w.$2) >= total / 2) tag,
      },
    );
  }

  /// Die ähnlichsten Dokumente zu [id] unter [candidates], ähnlichstes
  /// zuerst (für `more_like_id`).
  List<(int, double)> similar(int id, Iterable<int> candidates, {Map<int, DocVectors> vectors = const {}, int limit = 25}) {
    final sample = _samples[id];
    if (sample == null) return const [];
    final vector = vectors[id]?.spans.isNotEmpty ?? false ? vectors[id]!.mean : null;
    final scored = <(int, double)>[];
    for (final c in candidates) {
      final other = _samples[c];
      if (c == id || other == null) continue;
      final otherVector = vectors[c]?.spans.isNotEmpty ?? false ? vectors[c]!.mean : null;
      final s = _similarity(sample.words, otherVector == null ? null : vector, other, otherVector);
      if (s > 0.1) scored.add((c, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).toList();
  }

  int? predictCorrespondent(String text) => _correspondent?.predict(tokenize(text));
  int? predictDocumentType(String text) => _documentType?.predict(tokenize(text));
  int? predictStoragePath(String text) => _storagePath?.predict(tokenize(text));

  Set<int> predictTags(String text) {
    final t = tokenize(text);
    return {for (final e in _tags.entries) if (e.value.predict(t)) e.key};
  }

  static const _stopwords = {
    'der', 'die', 'das', 'und', 'oder', 'ein', 'eine', 'einer', 'eines', 'einem', 'einen',
    'mit', 'von', 'für', 'auf', 'ist', 'sind', 'den', 'dem', 'des', 'sie', 'ihr', 'ihre',
    'wir', 'uns', 'bei', 'aus', 'zum', 'zur', 'als', 'auch', 'nicht', 'wird', 'werden',
    'the', 'and', 'for', 'with', 'you', 'your', 'are', 'this', 'that', 'from',
  };

  /// Wörter ab drei Buchstaben, klein geschrieben, ohne Zahlen.
  static Map<String, int> tokenize(String text) {
    final counts = <String, int>{};
    var n = 0;
    for (final m in RegExp(r'\p{L}{3,}', unicode: true).allMatches(text.toLowerCase())) {
      final w = m.group(0)!;
      if (_stopwords.contains(w)) continue;
      counts[w] = (counts[w] ?? 0) + 1;
      if (++n >= 5000) break;
    }
    return counts;
  }
}

/// Ergebnis der Zuordnung; `null` bzw. leer = keine.
class Prediction {
  const Prediction({this.correspondent, this.documentType, this.storagePath, this.tags = const {}});
  final int? correspondent;
  final int? documentType;
  final int? storagePath;
  final Set<int> tags;
}

/// Ein Trainingsdokument: Wortgewichte und Zuordnungen (0 = keine oder
/// keine lernende).
class _Sample {
  _Sample(this.words, this.correspondent, this.documentType, this.storagePath, this.tags);
  final Map<String, double> words;
  final int correspondent;
  final int documentType;
  final int storagePath;
  final Set<int> tags;
}

/// Naive Bayes mit mehreren Klassen; Klasse 0 bedeutet „keine Zuordnung“.
class _Multiclass {
  final _docCount = <int, int>{};
  final _wordCount = <int, Map<String, int>>{};
  final _totalWords = <int, int>{};
  final _vocab = <String>{};
  int _docs = 0;

  /// Entscheiden ist erst sinnvoll, wenn es mindestens zwei Klassen gibt
  /// (z. B. ein Label und „keine Zuordnung“ oder zwei Labels).
  bool get hasClasses => _docCount.keys.any((c) => c != 0) && _docCount.length >= 2;

  void add(int label, Map<String, int> tokens) {
    _docs++;
    _docCount[label] = (_docCount[label] ?? 0) + 1;
    final wc = _wordCount.putIfAbsent(label, () => {});
    tokens.forEach((w, c) {
      wc[w] = (wc[w] ?? 0) + c;
      _totalWords[label] = (_totalWords[label] ?? 0) + c;
      _vocab.add(w);
    });
  }

  int? predict(Map<String, int> tokens) {
    if (_docs == 0 || tokens.isEmpty || _docCount.length < 2) return null;
    int? best;
    var bestScore = double.negativeInfinity;
    final v = _vocab.length + 1;
    for (final label in _docCount.keys) {
      var score = log(_docCount[label]! / _docs);
      final wc = _wordCount[label]!;
      final total = _totalWords[label] ?? 0;
      tokens.forEach((w, c) {
        score += c * log(((wc[w] ?? 0) + 1) / (total + v));
      });
      if (score > bestScore) {
        bestScore = score;
        best = label;
      }
    }
    return best == 0 ? null : best;
  }
}

/// Naive Bayes für eine Ja/Nein-Entscheidung (ein Tag pro Modell).
class _Binary {
  final _model = _Multiclass();
  int positives = 0;
  int negatives = 0;

  void add(bool hasTag, Map<String, int> tokens) {
    if (hasTag) {
      positives++;
    } else {
      negatives++;
    }
    _model.add(hasTag ? 1 : 0, tokens);
  }

  bool predict(Map<String, int> tokens) => _model.predict(tokens) == 1;
}
