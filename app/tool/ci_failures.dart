// Schreibt fehlgeschlagene Tests aus `flutter test --file-reporter
// json:<datei>` als Anmerkungen für GitHub Actions: Die Job-Logs sind nicht
// öffentlich lesbar, die Anmerkungen schon.
//
//   dart run tool/ci_failures.dart build/test-results.json
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final names = <int, String>{};
  final errors = <int, List<String>>{};
  final failed = <int>[];
  for (final line in File(args.single).readAsLinesSync()) {
    if (!line.startsWith('{')) continue;
    final e = jsonDecode(line) as Map<String, dynamic>;
    switch (e['type']) {
      case 'testStart':
        final test = e['test'] as Map<String, dynamic>;
        names[test['id'] as int] = test['name'] as String;
      case 'error':
        errors.putIfAbsent(e['testID'] as int, () => []).add('${e['error']}');
      case 'testDone':
        if (e['result'] != 'success' && e['hidden'] != true) failed.add(e['testID'] as int);
    }
  }
  String escape(String s) => s.replaceAll('%', '%25').replaceAll('\r', '').replaceAll('\n', '%0A');
  for (final id in failed) {
    final message = (errors[id] ?? const ['ohne Fehlermeldung']).join('\n').split('\n').take(12).join('\n');
    stdout.writeln('::error title=${escape(names[id] ?? 'Test $id')}::${escape(message)}');
  }
}
