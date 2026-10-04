import 'dart:io';

import 'package:logging/logging.dart';
import 'package:paperbuddy_server/paperbuddy_server.dart';

Future<void> main() async {
  Logger.root.level = Platform.environment['PAPERBUDDY_DEBUG'] == '1'
      ? Level.FINE
      : Level.INFO;
  Logger.root.onRecord.listen((r) {
    stdout.writeln(
      '${r.time.toIso8601String()} ${r.level.name.padRight(7)} '
      '[${r.loggerName}] ${r.message}${r.error == null ? '' : ' – ${r.error}'}',
    );
    if (r.stackTrace != null && r.level >= Level.SEVERE) {
      stdout.writeln(r.stackTrace);
    }
  });

  final server = await PaperbuddyServer.create(Config.fromEnvironment());
  await server.serve();

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      await server.close();
      exit(0);
    });
  }
}
