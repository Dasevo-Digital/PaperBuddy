import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../ai/index.dart';
import 'classifier.dart';

/// Matching-Algorithmen wie in Paperless-ngx.
abstract final class MatchingAlgorithm {
  static const none = 0;
  static const any = 1;
  static const all = 2;
  static const literal = 3;
  static const regex = 4;
  static const fuzzy = 5;
  static const auto = 6;
}

bool matches(String content, String match, int algorithm, bool insensitive) {
  if (match.trim().isEmpty) return false;
  final text = insensitive ? content.toLowerCase() : content;
  final pattern = insensitive ? match.toLowerCase() : match;
  List<String> words() => RegExp(
    r'"([^"]+)"|(\S+)',
  ).allMatches(pattern).map((m) => m.group(1) ?? m.group(2)!).toList();
  bool hasWord(String w) =>
      RegExp('\\b${RegExp.escape(w)}\\b', unicode: true).hasMatch(text);

  switch (algorithm) {
    case MatchingAlgorithm.any:
      return words().any(hasWord);
    case MatchingAlgorithm.all:
      return words().every(hasWord);
    case MatchingAlgorithm.literal:
      return hasWord(pattern);
    case MatchingAlgorithm.regex:
      try {
        return RegExp(
          match,
          caseSensitive: !insensitive,
          multiLine: true,
        ).hasMatch(content);
      } on FormatException {
        return false;
      }
    case MatchingAlgorithm.fuzzy:
      final simplified = text.replaceAll(RegExp(r'[^\w\s]', unicode: true), '');
      return simplified.contains(
        pattern.replaceAll(RegExp(r'[^\w\s]', unicode: true), ''),
      );
    default:
      // `auto` (lernendes Matching) folgt später.
      return false;
  }
}

class MatchResult {
  int? correspondent;
  int? documentType;
  int? storagePath;
  final tags = <int>{};
}

/// Zuordnung nach den Regeln der Labels. Labels mit „Auto“ entscheidet der
/// [classifier], sofern einer übergeben wird; mit [vector] (lokale KI) über
/// die ähnlichsten Dokumente in [vectors], ohne das Dokument [exclude].
MatchResult matchContent(
  Database db,
  String content, {
  DocumentClassifier? classifier,
  Float32List? vector,
  Map<int, DocVectors> vectors = const {},
  int? exclude,
}) {
  final result = MatchResult();
  late final prediction = classifier?.predict(content, vector: vector, vectors: vectors, exclude: exclude);
  int? first(String table, int? Function(Prediction) predicted) {
    for (final row in db.select('SELECT id, match, matching_algorithm, is_insensitive FROM $table')) {
      if (matches(content, row['match'] as String, row['matching_algorithm'] as int, row['is_insensitive'] == 1)) {
        return row['id'] as int;
      }
    }
    final p = prediction;
    return p == null ? null : predicted(p);
  }

  result.correspondent = first('correspondents', (p) => p.correspondent);
  result.documentType = first('document_types', (p) => p.documentType);
  result.storagePath = first('storage_paths', (p) => p.storagePath);
  for (final row in db.select('SELECT id, match, matching_algorithm, is_insensitive, is_inbox_tag FROM tags')) {
    if (row['is_inbox_tag'] == 1 ||
        matches(content, row['match'] as String, row['matching_algorithm'] as int, row['is_insensitive'] == 1)) {
      result.tags.add(row['id'] as int);
    }
  }
  if (classifier != null) result.tags.addAll(prediction!.tags);
  return result;
}

/// Sucht das erste plausible Datum im Text (deutsche und ISO-Schreibweise).
DateTime? findDate(String content) {
  const months = {
    'januar': 1,
    'jänner': 1,
    'februar': 2,
    'märz': 3,
    'april': 4,
    'mai': 5,
    'juni': 6,
    'juli': 7,
    'august': 8,
    'september': 9,
    'oktober': 10,
    'november': 11,
    'dezember': 12,
  };
  final patterns = <RegExp, DateTime? Function(Match)>{
    RegExp(r'\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b'): (m) =>
        _date(m[3]!, m[2]!, m[1]!),
    RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b'): (m) => _date(m[1]!, m[2]!, m[3]!),
    RegExp(
      r'\b(\d{1,2})\.\s?(' + months.keys.join('|') + r')\s+(\d{4})\b',
      caseSensitive: false,
    ): (m) =>
        _date(m[3]!, '${months[m[2]!.toLowerCase()]}', m[1]!),
  };
  DateTime? best;
  int bestPos = 1 << 30;
  patterns.forEach((re, build) {
    for (final m in re.allMatches(content)) {
      final d = build(m);
      if (d != null && m.start < bestPos) {
        best = d;
        bestPos = m.start;
        break;
      }
    }
  });
  return best;
}

DateTime? _date(String y, String m, String d) {
  final year = int.parse(y), month = int.parse(m), day = int.parse(d);
  if (year < 1900 || year > DateTime.now().year + 1) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  return date.month == month ? date : null;
}
