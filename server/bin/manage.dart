import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';

/// Verwaltungsbefehle, angelehnt an `manage.py` von Paperless-ngx.
void main(List<String> args) {
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
      default:
        stdout.writeln('Befehle: createsuperuser');
    }
  } finally {
    db.close();
  }
}
