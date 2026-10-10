// Was noch zu übersetzen ist: zählt deutsche Texte, die noch direkt in
// lib/ stehen (außerhalb von lib/l10n), je Datei, und die Texte in den ARB-Dateien.
// Einige bleiben absichtlich deutsch: Sprachnamen und Beispiele in Kommentaren.
//
//   dart run tool/l10n_report.dart [--top 20]
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final topIndex = args.indexOf('--top');
  final top = topIndex >= 0 ? int.parse(args[topIndex + 1]) : 15;
  final literal = RegExp(r"'((?:[^'\\\n]|\\.)*)'");
  final german = RegExp(
    r'[äöüÄÖÜß]|\b(der|die|das|und|nicht|ist|mit|für|ein|eine|auf|zu|du|dein|deine)\b'
    r'|^[A-ZÄÖÜ][a-zäöüß]{2,}$',
  );
  final counts = <String, int>{};
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File ||
        !file.path.endsWith('.dart') ||
        file.path.startsWith('lib/l10n/')) {
      continue;
    }
    var n = 0;
    for (final line in file.readAsLinesSync()) {
      final t = line.trim();
      if (t.startsWith('import ') ||
          t.startsWith('export ') ||
          t.startsWith('part ') ||
          t.startsWith('//')) {
        continue;
      }
      for (final m in literal.allMatches(line)) {
        final text = m[1]!;
        if (text.startsWith('package:') ||
            text.contains('/') && !text.contains(' ')) {
          continue;
        }
        if (german.hasMatch(text)) n++;
      }
    }
    if (n > 0) counts[file.path] = n;
  }
  final keys =
      (jsonDecode(File('lib/l10n/app_de.arb').readAsStringSync()) as Map).keys
          .where((k) => !(k as String).startsWith('@'))
          .length;
  final total = counts.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln(
    'Übersetzt (ARB): $keys Texte · noch fest im Code: etwa $total Texte in '
    '${counts.length} Dateien '
    '(${(100 * keys / (keys + total)).toStringAsFixed(0)} %)',
  );
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted.take(top)) {
    stdout.writeln('${e.value.toString().padLeft(5)}  ${e.key}');
  }
}
