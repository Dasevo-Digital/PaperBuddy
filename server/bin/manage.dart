import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:sqlite3/sqlite3.dart';

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
      case 'disable-totp':
        final name = args.elementAtOrNull(1) ?? (throw ArgumentError('Benutzername fehlt'));
        final row = db.select('SELECT id FROM users WHERE username = ?', [name]).firstOrNull;
        if (row == null) {
          stderr.writeln('Benutzer "$name" nicht gefunden.');
          exitCode = 1;
          return;
        }
        auth.disableTotp(row['id'] as int);
        stdout.writeln('Zwei-Faktor-Anmeldung für "$name" ausgeschaltet.');
      case 'backup':
        final dir = args.elementAtOrNull(1) ?? config.backupDir ?? (throw ArgumentError('Zielordner fehlt'));
        final backups = _backups(config, db, await createStore(config));
        final passphrase = _passphrase(config, confirm: true);
        final created = await backups.create(dir, passphrase);
        stdout.writeln('Gesichert: $created');
        final checked = await backups.verify(created.file, passphrase);
        stdout.writeln(checked.ok ? 'Geprüft: in Ordnung.' : 'Prüfung fehlgeschlagen:');
        checked.problems.followedBy(created.problems).forEach(stderr.writeln);
        if (!checked.ok) exitCode = 1;
      case 'verify-backup':
        final file = args.elementAtOrNull(1) ?? (throw ArgumentError('Sicherungsdatei fehlt'));
        final report = await _backups(config, db, await createStore(config)).verify(file, _passphrase(config));
        stdout.writeln(report.ok ? 'In Ordnung: $report' : 'Fehlerhaft: $report');
        if (!report.ok) exitCode = 1;
      case 'restore-backup':
        if (args.length < 3) throw ArgumentError('Aufruf: restore-backup <datei> <zielordner>');
        final report = await _backups(config, db, await createStore(config)).restore(args[1], _passphrase(config), args[2]);
        stdout.writeln(report.ok ? 'Wiederhergestellt nach ${args[2]}: $report' : 'Fehlerhaft: $report');
        if (report.ok) {
          stdout.writeln('Server anhalten, PAPERBUDDY_DATA_DIR auf diesen Ordner setzen (oder den Inhalt '
              'hineinkopieren) und neu starten.');
        } else {
          exitCode = 1;
        }
      case 'extract-invoices':
        // Vorhandene Dokumente: E-Rechnung im Original, sonst der Text.
        final store = await createStore(config);
        final tools = ExternalTools(ocrLanguage: config.ocrLanguage);
        final fields = InvoiceFields(db);
        var found = 0;
        for (final d in db.select('SELECT id, content, mime_type, original_path FROM documents WHERE deleted_at IS NULL')) {
          InvoiceData? data;
          if (d['mime_type'] == 'application/pdf') {
            final file = await store.get(d['original_path'] as String);
            final xml = file == null ? null : await tools.pdfInvoiceXml(file.path);
            if (xml != null) data = parseInvoiceXml(xml);
          }
          data ??= invoiceFromText(d['content'] as String);
          if (data != null && fields.apply(d['id'] as int, data) > 0) found++;
        }
        stdout.writeln('Rechnungsdaten bei $found Dokument(en) ergänzt.');
      case 'rename-files':
        final n = await FilenameGenerator(db, await createStore(config), format: config.filenameFormat).relocateAll();
        stdout.writeln('$n Dokument(e) neu abgelegt.');
      default:
        stdout.writeln('''Befehle:
  createsuperuser                    Administrator anlegen
  export <ordner>                    alles exportieren (Paperless-Format, auch als Backup)
  import <ordner>                    Export von PaperBuddy oder Paperless-ngx einlesen
  import-paperless <url> <token>     direkt von einem laufenden Paperless-ngx übernehmen
  backup [ordner]                    verschlüsselte Gesamtsicherung anlegen und prüfen
  verify-backup <datei>              Sicherung entschlüsseln und prüfen
  restore-backup <datei> <ordner>    Sicherung in einen leeren Ordner entpacken
  extract-invoices                   Rechnungsdaten vorhandener Dokumente in Custom Fields eintragen
  rename-files                       Dateien nach FILENAME_FORMAT/Speicherpfaden neu ablegen
  disable-totp <benutzer>            Zwei-Faktor-Anmeldung ausschalten (Telefon verloren)''');
    }
  } on ArgumentError catch (e) {
    // Fehlende oder falsche Angaben: Meldung statt Stacktrace.
    stderr.writeln(e.message);
    exitCode = 64;
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on FileSystemException catch (e) {
    stderr.writeln('${e.path ?? ''}: ${e.osError?.message ?? e.message}');
    exitCode = 1;
  } finally {
    db.close();
  }
}

BackupService _backups(Config config, Database db, BlobStore store) =>
    BackupService(db: db, store: store, workDir: p.join(config.dataDir, 'work'));

/// Aus PAPERBUDDY_BACKUP_PASSPHRASE(_FILE), sonst am Terminal abfragen.
String _passphrase(Config config, {bool confirm = false}) {
  final configured = config.backupPassphrase;
  if (configured != null && configured.isNotEmpty) return configured;
  if (!stdin.hasTerminal) throw ArgumentError('PAPERBUDDY_BACKUP_PASSPHRASE setzen');
  String ask(String prompt) {
    stdout.write(prompt);
    stdin.echoMode = false;
    final value = stdin.readLineSync() ?? '';
    stdin.echoMode = true;
    stdout.writeln();
    return value;
  }

  final value = ask('Passphrase: ');
  if (value.length < 12) throw ArgumentError('Passphrase mindestens 12 Zeichen');
  if (confirm && ask('Passphrase wiederholen: ') != value) throw ArgumentError('Passphrasen stimmen nicht überein');
  return value;
}
