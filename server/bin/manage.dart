import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';

/// Verwaltungsbefehle, angelehnt an `manage.py` von Paperless-ngx.
Future<void> main(List<String> args) async {
  final config = Config.fromEnvironment();
  final db = openDatabase(config.databasePath);
  final auth = AuthService(db);
  try {
    switch (args.firstOrNull) {
      case 'createsuperuser':
        stdout.write('Benutzername: ');
        final user = stdin.readLineSync()?.trim() ?? '';
        stdin.echoMode = false;
        stdout.write('Passwort: ');
        final password = stdin.readLineSync() ?? '';
        stdin.echoMode = true;
        stdout.writeln();
        if (user.isEmpty || password.length < 8) {
          stderr.writeln(
            'Benutzername erforderlich, Passwort mindestens 8 Zeichen.',
          );
          exitCode = 1;
          return;
        }
        auth.createUser(user, password, superuser: true);
        stdout.writeln('Administrator "$user" angelegt.');
      case 'export':
        final dir = args.elementAtOrNull(1) ?? (throw ArgumentError('Zielordner fehlt'));
        final report = await Transfer(db, await createStore(config)).export(dir);
        stdout.writeln('Exportiert nach $dir: $report');
        report.warnings.forEach(stderr.writeln);
      case 'import':
        final dir = args.elementAtOrNull(1) ?? (throw ArgumentError('Export-Ordner fehlt'));
        final report = await Transfer(db, await createStore(config)).importDirectory(dir);
        stdout.writeln('Importiert: $report');
        report.warnings.forEach(stderr.writeln);
      case 'import-paperless':
        if (args.length < 3) throw ArgumentError('Aufruf: import-paperless <url> <token>');
        final report = await Transfer(db, await createStore(config)).importFromPaperless(
          Uri.parse(args[1]),
          args[2],
          progress: stdout.writeln,
        );
        stdout.writeln('Importiert: $report');
        report.warnings.forEach(stderr.writeln);
      case 'rename-files':
        final n = await FilenameGenerator(db, await createStore(config), format: config.filenameFormat).relocateAll();
        stdout.writeln('$n Dokument(e) neu abgelegt.');
      default:
        stdout.writeln('''Befehle:
  createsuperuser                    Administrator anlegen
  export <ordner>                    alles exportieren (Paperless-Format, auch als Backup)
  import <ordner>                    Export von PaperBuddy oder Paperless-ngx einlesen
  import-paperless <url> <token>     direkt von einem laufenden Paperless-ngx übernehmen
  rename-files                       Dateien nach FILENAME_FORMAT/Speicherpfaden neu ablegen''');
    }
  } finally {
    db.close();
  }
}
