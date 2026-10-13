import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';

/// SentencePiece-Unigram-Tokenizer für die XLM-RoBERTa-Familie
/// (multilingual-e5), gelesen aus der `tokenizer.json` des Modells.
///
/// Die Schritte entsprechen der Bibliothek `tokenizers` von HuggingFace, mit
/// der das Modell trainiert wurde; `test/fixtures/e5_tokens.json` hält ihre
/// Ausgabe fest:
///
/// 1. Normalisieren mit der vorberechneten Zeichentabelle von SentencePiece
///    (`Precompiled`, im Kern NFKC), danach mehrfache Leerzeichen zu einem.
/// 2. Metaspace: Leerzeichen werden zu `▁`, jedes Wort beginnt mit `▁`.
/// 3. Je Wort die wahrscheinlichste Zerlegung über das Wörterbuch (Viterbi).
/// 4. `<s>` davor, `</s>` dahinter.
class UnigramTokenizer {
  UnigramTokenizer._(this._ids, this._scores, this._charsmap, this.unkId, this._maxPieceLength)
      : _unkScore = _scores.reduce((a, b) => a < b ? a : b) - 10;

  final Map<String, int> _ids;
  final Float64List _scores;
  final _Charsmap? _charsmap;
  final int _maxPieceLength;
  final double _unkScore;

  final int unkId;
  static const bosId = 0;
  static const padId = 1;
  static const eosId = 2;
  static const _metaspace = '▁';

  /// Liest die `tokenizer.json` ohne `jsonDecode`: Das Wörterbuch hat
  /// 250.000 Einträge, als JSON-Baum belegte es kurzzeitig rund 150 MB.
  static Future<UnigramTokenizer> load(String path) async => fromBytes(await File(path).readAsBytes());

  static UnigramTokenizer fromBytes(Uint8List bytes) {
    final s = _Scanner(bytes);
    final model = s.find('"model"');
    if (model < 0) throw const FormatException('tokenizer.json ohne "model"');
    s.pos = model;
    if (s.find('"type":"Unigram"', model) < 0 && s.find('"type": "Unigram"', model) < 0) {
      throw const FormatException('Kein Unigram-Tokenizer');
    }
    final unkAt = s.find('"unk_id"', model);
    var unkId = 3;
    if (unkAt >= 0) {
      s.pos = unkAt + 8;
      s.skipTo(0x3a); // :
      s.pos++;
      s.skipSpace();
      unkId = s.readNumber().toInt();
    }
    s.pos = s.find('"vocab"', model);
    if (s.pos < 0) throw const FormatException('tokenizer.json ohne Wörterbuch');
    s.skipTo(0x5b); // [
    s.pos++;
    final ids = <String, int>{};
    final scores = <double>[];
    var maxLength = 1;
    while (true) {
      s.skipSpace();
      if (s.peek == 0x5d) break; // ]
      if (s.peek == 0x2c) {
        s.pos++;
        continue;
      }
      s.expect(0x5b);
      s.skipSpace();
      final piece = s.readString();
      s.skipSpace();
      s.expect(0x2c);
      s.skipSpace();
      final score = s.readNumber();
      s.skipSpace();
      s.expect(0x5d);
      ids.putIfAbsent(piece, () => scores.length);
      scores.add(score);
      final length = piece.runes.length;
      if (length > maxLength) maxLength = length;
    }
    String? charsmap;
    final cm = s.find('"precompiled_charsmap"');
    if (cm >= 0) {
      s.pos = cm + 22;
      s.skipTo(0x3a);
      s.pos++;
      s.skipSpace();
      if (s.peek == 0x22) charsmap = s.readString();
    }
    return UnigramTokenizer._(
      ids,
      Float64List.fromList(scores),
      charsmap == null || charsmap.isEmpty ? null : _Charsmap(base64.decode(charsmap)),
      unkId,
      maxLength,
    );
  }

  /// Kennungen für das Modell: `<s> … </s>`, höchstens [maxLength] lang.
  List<int> encode(String text, {int maxLength = 512}) {
    final ids = tokenize(text);
    if (ids.length > maxLength - 2) ids.length = maxLength - 2;
    return [bosId, ...ids, eosId];
  }

  /// Kennungen ohne Sonderzeichen.
  List<int> tokenize(String text) {
    final normalized = normalize(text);
    if (normalized.isEmpty) return [];
    var spaced = normalized.replaceAll(' ', _metaspace);
    if (!spaced.startsWith(_metaspace)) spaced = '$_metaspace$spaced';
    final ids = <int>[];
    // Metaspace trennt vor jedem `▁`; das Zeichen gehört zum folgenden Wort.
    var start = 0;
    for (var i = 1; i <= spaced.length; i++) {
      if (i == spaced.length || spaced.startsWith(_metaspace, i)) {
        _viterbi(spaced.substring(start, i), ids);
        start = i;
      }
    }
    return ids;
  }

  /// Wie `Precompiled` in `tokenizers`: je Graphem (kürzer als 6 Bytes) den
  /// ersten Treffer der Tabelle, sonst Zeichen für Zeichen. Danach mehrfache
  /// Leerzeichen zu einem.
  String normalize(String text) {
    final map = _charsmap;
    if (map == null) return text.replaceAll(RegExp(' {2,}'), ' ');
    final out = StringBuffer();
    for (final grapheme in text.characters) {
      final bytes = utf8.encode(grapheme);
      if (bytes.length < 6) {
        final replaced = map.transform(bytes);
        if (replaced != null) {
          out.write(replaced);
          continue;
        }
      }
      for (final rune in grapheme.runes) {
        final char = String.fromCharCode(rune);
        out.write(map.transform(utf8.encode(char)) ?? char);
      }
    }
    return out.toString().replaceAll(RegExp(' {2,}'), ' ');
  }

  /// Beste Zerlegung eines Wortes wie `Unigram::encode_optimized`: ein
  /// unbekanntes Zeichen nur, wenn es kein Stück aus genau diesem Zeichen
  /// gibt; aufeinanderfolgende unbekannte Zeichen werden eins.
  void _viterbi(String word, List<int> into) {
    final chars = word.runes.toList(growable: false);
    final n = chars.length;
    final best = Float64List(n + 1);
    final from = Int32List(n + 1)..fillRange(1, n + 1, -1);
    final piece = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      if (i > 0 && from[i] < 0) continue;
      final base = best[i];
      var single = false;
      final limit = i + _maxPieceLength > n ? n - i : _maxPieceLength;
      for (var l = 1; l <= limit; l++) {
        final id = _ids[String.fromCharCodes(chars, i, i + l)];
        if (id == null) continue;
        final score = base + _scores[id];
        if (from[i + l] < 0 || score > best[i + l]) {
          best[i + l] = score;
          from[i + l] = i;
          piece[i + l] = id;
        }
        if (l == 1) single = true;
      }
      if (!single) {
        final score = base + _unkScore;
        if (from[i + 1] < 0 || score > best[i + 1]) {
          best[i + 1] = score;
          from[i + 1] = i;
          piece[i + 1] = unkId;
        }
      }
    }
    final ids = <int>[];
    for (var end = n; end > 0; end = from[end]) {
      final id = piece[end];
      if (id == unkId && ids.isNotEmpty && ids.last == unkId) continue;
      ids.add(id);
    }
    into.addAll(ids.reversed);
  }
}

/// Die vorberechnete Normalisierungstabelle von SentencePiece: ein
/// Double-Array-Trie über UTF-8-Bytes, dessen Blätter auf nullterminierte
/// Ersatztexte zeigen.
class _Charsmap {
  _Charsmap(Uint8List blob) {
    final data = ByteData.sublistView(blob);
    final trieSize = data.getUint32(0, Endian.little);
    _trie = Uint32List(trieSize ~/ 4);
    for (var i = 0; i < _trie.length; i++) {
      _trie[i] = data.getUint32(4 + i * 4, Endian.little);
    }
    _normalized = Uint8List.sublistView(blob, 4 + trieSize);
  }

  late final Uint32List _trie;
  late final Uint8List _normalized;
  final _cache = <String, String?>{};

  static bool _hasLeaf(int unit) => (unit >> 8) & 1 == 1;
  static int _value(int unit) => unit & 0x7fffffff;
  static int _label(int unit) => unit & 0x800000ff;
  static int _offset(int unit) => (unit >> 10) << ((unit & (1 << 9)) >> 6);

  /// Ersatz für [key] nach dem kürzesten Präfix-Treffer, sonst `null`.
  String? transform(List<int> key) => _cache.putIfAbsent(String.fromCharCodes(key), () {
        var pos = _offset(_trie[0]);
        for (final c in key) {
          if (c == 0) break;
          pos ^= c;
          final unit = _trie[pos];
          if (_label(unit) != c) return null;
          pos ^= _offset(unit);
          if (_hasLeaf(unit)) {
            final start = _value(_trie[pos]);
            var end = start;
            while (end < _normalized.length && _normalized[end] != 0) {
              end++;
            }
            return utf8.decode(Uint8List.sublistView(_normalized, start, end));
          }
        }
        return null;
      });
}

/// Gerade so viel JSON, wie die `tokenizer.json` braucht.
class _Scanner {
  _Scanner(this.bytes);
  final Uint8List bytes;
  int pos = 0;

  int get peek => bytes[pos];

  /// Erste Stelle von [needle] ab [from], sonst -1.
  int find(String needle, [int from = 0]) {
    final n = utf8.encode(needle);
    outer:
    for (var i = from; i <= bytes.length - n.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  void skipSpace() {
    while (pos < bytes.length && (bytes[pos] == 0x20 || bytes[pos] == 0x0a || bytes[pos] == 0x0d || bytes[pos] == 0x09)) {
      pos++;
    }
  }

  void skipTo(int byte) {
    while (pos < bytes.length && bytes[pos] != byte) {
      pos++;
    }
  }

  void expect(int byte) {
    if (pos >= bytes.length || bytes[pos] != byte) {
      throw FormatException('tokenizer.json: ${String.fromCharCode(byte)} erwartet', null, pos);
    }
    pos++;
  }

  String readString() {
    expect(0x22);
    final start = pos;
    var escaped = false;
    while (bytes[pos] != 0x22) {
      if (bytes[pos] == 0x5c) {
        escaped = true;
        pos++;
      }
      pos++;
    }
    final raw = Uint8List.sublistView(bytes, start, pos);
    pos++;
    // Nur Stücke mit Escapes (\", \\, \uXXXX) über den JSON-Decoder.
    return escaped ? jsonDecode('"${utf8.decode(raw)}"') as String : utf8.decode(raw);
  }

  double readNumber() {
    final start = pos;
    while (pos < bytes.length && (bytes[pos] == 0x2d || bytes[pos] == 0x2b || bytes[pos] == 0x2e ||
        bytes[pos] == 0x65 || bytes[pos] == 0x45 || (bytes[pos] >= 0x30 && bytes[pos] <= 0x39))) {
      pos++;
    }
    return double.parse(String.fromCharCodes(bytes, start, pos));
  }
}
