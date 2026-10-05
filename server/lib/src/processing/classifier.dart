import 'dart:math';

import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

final _log = Logger('classifier');

/// Lernendes Matching (`matching_algorithm = 6`, „Auto“).
///
/// Paperless-ngx trainiert dafür ein neuronales Netz mit scikit-learn. Hier
/// genügt ein multinomialer Naive-Bayes-Klassifikator auf Wortzählungen: er
/// lernt aus den vorhandenen Zuordnungen, ist in Millisekunden trainiert und
/// braucht keine externen Abhängigkeiten.
class DocumentClassifier {
  DocumentClassifier(this.db);
  final Database db;

  _Multiclass? _correspondent;
  _Multiclass? _documentType;
  _Multiclass? _storagePath;
  Map<int, _Binary> _tags = {};
  String? _trainedOn;

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
    _trainedOn = fp;
    _log.fine('Trainiert auf ${docs.length} Dokumenten in ${sw.elapsedMilliseconds} ms');
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
