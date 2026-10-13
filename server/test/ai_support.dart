import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:paperbuddy_server/src/ai/embedder.dart';

/// Wo `tool/fetch_ai.sh` ONNX Runtime und Modelle für die Tests ablegt.
final aiCache = (
  models: '${Platform.environment['PAPERBUDDY_AI_CACHE'] ?? '.dart_tool/paperbuddy_ai'}/models',
  runtime: '${Platform.environment['PAPERBUDDY_AI_CACHE'] ?? '.dart_tool/paperbuddy_ai'}/onnxruntime/'
      '${Platform.isMacOS ? 'libonnxruntime.dylib' : 'libonnxruntime.so'}',
);

/// Ein Modell für Tests ohne ONNX: Jedes Wort bekommt einen festen
/// Zufallsvektor, ein Text die normierte Summe seiner Wörter. Texte mit
/// gemeinsamen Wörtern liegen also nah beieinander.
class FakeEmbedder implements TextEmbedder {
  FakeEmbedder({this.wordsPerChunk = 40});
  final int wordsPerChunk;
  var calls = 0;

  @override
  String get model => 'fake';
  @override
  int get dimensions => 64;

  Float32List _vector(Iterable<String> words) {
    final v = Float32List(dimensions);
    for (final w in words) {
      final r = Random(w.toLowerCase().hashCode);
      for (var i = 0; i < dimensions; i++) {
        v[i] += r.nextDouble() * 2 - 1;
      }
    }
    return normalize(v);
  }

  static Iterable<String> _words(String text) =>
      RegExp(r'\p{L}{3,}', unicode: true).allMatches(text).map((m) => m.group(0)!);

  @override
  Future<Float32List> query(String text) async {
    calls++;
    return _vector(_words(text));
  }

  @override
  Future<List<Passage>> passages(String title, String content) async {
    calls++;
    final matches = RegExp(r'\S+').allMatches(content).toList();
    final out = <Passage>[];
    for (var i = 0; i < matches.length; i += wordsPerChunk) {
      final part = matches.skip(i).take(wordsPerChunk).toList();
      final text = [if (i == 0) title, ...part.map((m) => m.group(0)!)].join(' ');
      out.add(Passage(_vector(_words(text)), part.first.start, part.last.end));
    }
    if (out.isEmpty && title.isNotEmpty) out.add(Passage(_vector(_words(title)), 0, 0));
    return out;
  }

  @override
  Future<void> close() async {}
}
