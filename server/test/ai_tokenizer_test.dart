import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/src/ai/tokenizer.dart';
import 'package:test/test.dart';

import 'ai_support.dart';

void main() {
  final tokenizerFile = File('${aiCache.models}/multilingual-e5-small/tokenizer.json');

  test('zerlegt wie die tokenizers-Bibliothek von HuggingFace', () async {
    final tokenizer = await UnigramTokenizer.load(tokenizerFile.path);
    final samples = jsonDecode(File('test/fixtures/e5_tokens.json').readAsStringSync()) as List;
    for (final s in samples) {
      expect(tokenizer.encode(s['text'] as String), s['ids'], reason: jsonEncode(s['text']));
    }
  }, skip: tokenizerFile.existsSync() ? false : 'Modell fehlt (server/tool/fetch_ai.sh)');
}
