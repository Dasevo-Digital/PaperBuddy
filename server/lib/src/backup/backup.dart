import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../storage.dart';
import '../version.dart';
import 'age.dart';
import 'byte_reader.dart';
import 'tar.dart';

final _log = Logger('backup');

/// Zeitgesteuerte Sicherung (`BACKUP_DIR` und Passphrase gesetzt).
class BackupSettings {
  const BackupSettings({
    required this.dir,
    required this.passphrase,
    this.hour = 3,
    this.minute = 0,
    this.keep = 7,
  });

  final String dir;
  final String passphrase;
  final int hour, minute;

  /// So viele Sicherungen bleiben liegen; ältere werden gelöscht.
  final int keep;
}

/// Ergebnis einer Sicherung oder ihrer Prüfung.
class BackupReport {
  BackupReport(this.file);
  final String file;
  int files = 0, bytes = 0, documents = 0;
  final problems = <String>[];
  bool get ok => problems.isEmpty;

  Map<String, dynamic> toJson() => {
    'file': file,
    'files': files,
    'bytes': bytes,
    'documents': documents,
    'ok': ok,
    'problems': problems,
  };

  @override
  String toString() => [
    p.basename(file),
    '$documents Dokumente',
    '$files Dateien',
    '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
    if (!ok) 'Probleme: ${problems.join('; ')}',
  ].join(', ');
}

/// Verschlüsselte Gesamtsicherung: ein tar-Archiv im age-Format mit
///
/// * `paperbuddy.sqlite3` – konsistenter Schnappschuss (`VACUUM INTO`),
/// * `media/<schlüssel>` – Originale, Archiv-PDFs, Vorschaubilder, Versionen,
/// * `paperbuddy-backup.json` – Zähler je Tabelle und SHA-256 je Datei.
///
/// Entpackt in `DATA_DIR` ergibt das wieder einen lauffähigen Server
/// (`MEDIA_ROOT` = `DATA_DIR/media`). Ohne PaperBuddy:
/// `age -d sicherung.tar.age | tar x`.
class BackupService {
  BackupService({
    required this.db,
    required this.store,
    required this.workDir,
    this.settings,
    this.statusFile,
  });

  final Database db;
  final BlobStore store;
  final String workDir;
  final BackupSettings? settings;

  /// Ergebnis der letzten zeitgesteuerten Sicherung (JSON).
  final String? statusFile;

  static const manifestName = 'paperbuddy-backup.json';
  static const databaseName = 'paperbuddy.sqlite3';
  static final _fileName = RegExp(r'^paperbuddy-\d{8}-\d{6}\.tar\.age$');

  Timer? _timer;
  bool _running = false;

  /// Letzte zeitgesteuerte Sicherung, z. B. für den Status-Endpunkt.
  Map<String, dynamic>? get lastStatus {
    final f = statusFile == null ? null : File(statusFile!);
    if (f == null || !f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  // Zeitplan -----------------------------------------------------------------

  void start() {
    final s = settings;
    if (s == null) return;
    _schedule(s);
  }

  void stop() => _timer?.cancel();

  void _schedule(BackupSettings s) {
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, s.hour, s.minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    _log.info('Nächste Sicherung: $next nach ${s.dir}');
    _timer = Timer(next.difference(now), () async {
      await runScheduled();
      _schedule(s);
    });
  }

  /// Sichern, prüfen, alte Sicherungen aufräumen, Ergebnis merken.
  Future<BackupReport?> runScheduled() async {
    final s = settings;
    if (s == null || _running) return null;
    final started = DateTime.now();
    BackupReport? report;
    try {
      final created = await create(s.dir, s.passphrase);
      report = await verify(created.file, s.passphrase);
      report.problems.insertAll(0, created.problems);
      if (report.ok) {
        prune(s.dir, s.keep);
        _log.info('Sicherung geprüft: $report');
      } else {
        _log.severe('Sicherung fehlerhaft: $report');
      }
    } catch (e, st) {
      _log.severe('Sicherung fehlgeschlagen', e, st);
      report = BackupReport('')..problems.add('$e');
    }
    if (statusFile != null) {
      await File(statusFile!).writeAsString(jsonEncode({
        ...report.toJson(),
        'started': started.toIso8601String(),
        'seconds': DateTime.now().difference(started).inSeconds,
      }));
    }
    return report;
  }

  /// Löscht die ältesten Sicherungen, bis höchstens [keep] übrig sind. Nur
  /// Dateien, die PaperBuddy selbst angelegt hat.
  List<String> prune(String dir, int keep) {
    final files = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => _fileName.hasMatch(p.basename(f.path)))
        .toList()
      ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    final removed = <String>[];
    for (final f in files.skip(keep < 1 ? 1 : keep)) {
      f.deleteSync();
      removed.add(f.path);
    }
    return removed;
  }

  // Sichern ------------------------------------------------------------------

  /// Schreibt eine neue Sicherung nach [targetDir] und liefert ihren Pfad.
  Future<BackupReport> create(String targetDir, String passphrase, {int workFactor = Age.defaultWorkFactor}) async {
    if (_running) throw StateError('Es läuft bereits eine Sicherung');
    _running = true;
    final stamp = _stamp(DateTime.now());
    final target = p.join(targetDir, 'paperbuddy-$stamp.tar.age');
    final partial = '$target.partial';
    final snapshot = p.join(workDir, 'backup-$stamp.sqlite3');
    final report = BackupReport(target);
    RandomAccessFile? out;
    try {
      await Directory(targetDir).create(recursive: true);
      await Directory(workDir).create(recursive: true);
      db.execute('VACUUM INTO ?', [snapshot]);
      final keys = _mediaKeys(snapshot);
      out = await File(partial).open(mode: FileMode.write);
      final age = await Age.writer(out, passphrase, workFactor: workFactor);
      final tar = TarWriter(age.add);
      final files = <String, Map<String, Object>>{};

      Future<void> add(String name, File file) async {
        final digest = _Digest();
        if (!await tar.addFile(name, file, onData: digest.add)) {
          report.problems.add('$name hat sich während der Sicherung geändert');
        }
        files[name] = {'size': digest.size, 'sha256': digest.close()};
        report.files++;
        report.bytes += digest.size;
      }

      await add(databaseName, File(snapshot));
      final missing = <String>[];
      for (final key in keys) {
        final file = await store.get(key);
        if (file == null) {
          missing.add(key);
          continue;
        }
        await add('media/$key', file);
      }
      if (missing.isNotEmpty) report.problems.add('${missing.length} Datei(en) fehlen im Speicher');
      final counts = _counts(snapshot);
      report.documents = counts['documents'] ?? 0;
      await tar.addBytes(
        manifestName,
        utf8.encode(const JsonEncoder.withIndent('  ').convert({
          'format': 1,
          'paperbuddy': paperbuddyVersion,
          'created': DateTime.now().toUtc().toIso8601String(),
          'counts': counts,
          'files': files,
          'missing': missing,
        })),
      );
      await tar.close();
      await age.close();
      await out.close();
      out = null;
      await File(partial).rename(target);
      return report;
    } finally {
      await out?.close();
      for (final f in [File(partial), File(snapshot)]) {
        if (f.existsSync()) f.deleteSync();
      }
      _running = false;
    }
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Alle Dateischlüssel aus dem Schnappschuss, auch von Versionen und
  /// Dokumenten im Papierkorb.
  static List<String> _mediaKeys(String snapshot) {
    final snap = sqlite3.open(snapshot, mode: OpenMode.readOnly);
    try {
      final keys = <String>{};
      for (final table in ['documents', 'document_versions']) {
        for (final r in snap.select('SELECT original_path, archive_path, thumbnail_path FROM $table')) {
          for (final v in r.values) {
            if (v is String && v.isNotEmpty) keys.add(v);
          }
        }
      }
      return keys.toList()..sort();
    } finally {
      snap.close();
    }
  }

  static Map<String, int> _counts(String database) {
    final snap = sqlite3.open(database, mode: OpenMode.readOnly);
    try {
      return {
        for (final t in snap.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        ))
          t['name'] as String: snap.select('SELECT COUNT(*) AS n FROM "${t['name']}"').first['n'] as int,
      };
    } finally {
      snap.close();
    }
  }

  // Prüfen und wiederherstellen ----------------------------------------------

  /// Entschlüsselt die ganze Sicherung, rechnet jede Datei gegen das Manifest
  /// und spielt die Datenbank in ein Temp-Verzeichnis zurück
  /// (`integrity_check`, Zähler je Tabelle, vorhandene Dateien).
  Future<BackupReport> verify(String file, String passphrase) => _read(file, passphrase);

  /// Entpackt die Sicherung nach [targetDir] (Datenbank und `media/`) und
  /// prüft sie dabei wie [verify]. Überschreibt nichts.
  Future<BackupReport> restore(String file, String passphrase, String targetDir) async {
    if (File(p.join(targetDir, databaseName)).existsSync() || Directory(p.join(targetDir, 'media')).existsSync()) {
      throw StateError('$targetDir enthält schon Daten; bitte einen leeren Ordner angeben');
    }
    return _read(file, passphrase, extractTo: targetDir);
  }

  Future<BackupReport> _read(String file, String passphrase, {String? extractTo}) async {
    final report = BackupReport(file);
    final temp = await Directory(workDir).create(recursive: true).then((d) => d.createTemp('verify-'));
    final hashes = <String, (int, String)>{};
    Map<String, dynamic>? manifest;
    final reader = ByteReader(Age.decrypt(File(file).openRead(), passphrase));
    try {
      await TarReader(reader).forEach((name, size, read) async {
        final safe = p.posix.normalize(name);
        if (p.posix.isAbsolute(safe) || safe.startsWith('..') || safe != name) {
          throw FormatException('Ungültiger Name im Archiv: $name');
        }
        final digest = _Digest();
        final keep = <int>[];
        final targets = <String>[
          if (extractTo != null) p.join(extractTo, safe),
          if (name == databaseName && extractTo == null) p.join(temp.path, databaseName),
        ];
        final sinks = <RandomAccessFile>[];
        for (final t in targets) {
          await Directory(p.dirname(t)).create(recursive: true);
          sinks.add(await File(t).open(mode: FileMode.writeOnly));
        }
        try {
          await read((chunk) async {
            digest.add(chunk);
            if (name == manifestName) keep.addAll(chunk);
            for (final s in sinks) {
              await s.writeFrom(chunk);
            }
          });
        } finally {
          for (final s in sinks) {
            await s.close();
          }
        }
        if (name == manifestName) {
          manifest = jsonDecode(utf8.decode(keep)) as Map<String, dynamic>;
        } else {
          hashes[name] = (digest.size, digest.close());
          report.files++;
          report.bytes += digest.size;
        }
      });
      // Bis zum Schluss entschlüsseln, damit auch der letzte Block geprüft ist.
      if (!await reader.atEnd()) throw const FormatException('Daten nach dem Archivende');
      final m = manifest;
      if (m == null) throw const FormatException('Manifest fehlt in der Sicherung');
      final files = (m['files'] as Map).cast<String, dynamic>();
      for (final MapEntry(key: name, value: info) in files.entries) {
        final got = hashes[name];
        if (got == null) {
          report.problems.add('$name fehlt');
        } else if (got.$1 != info['size'] || got.$2 != info['sha256']) {
          report.problems.add('$name ist beschädigt');
        }
      }
      for (final name in hashes.keys.where((n) => !files.containsKey(n))) {
        report.problems.add('$name steht nicht im Manifest');
      }
      for (final key in (m['missing'] as List? ?? const [])) {
        report.problems.add('media/$key fehlte schon beim Sichern');
      }
      _checkDatabase(
        p.join(extractTo ?? temp.path, databaseName),
        (m['counts'] as Map).cast<String, dynamic>(),
        hashes.keys.toSet(),
        report,
      );
    } on AgeException catch (e) {
      report.problems.add('$e');
    } on FormatException catch (e) {
      report.problems.add(e.message);
    } on StateError catch (e) {
      report.problems.add(e.message);
    } on FileSystemException catch (e) {
      report.problems.add('${e.path ?? file}: ${e.osError?.message ?? e.message}');
    } finally {
      await reader.cancel();
      await temp.delete(recursive: true);
    }
    return report;
  }

  void _checkDatabase(String path, Map<String, dynamic> counts, Set<String> names, BackupReport report) {
    if (!File(path).existsSync()) {
      report.problems.add('Datenbank fehlt in der Sicherung');
      return;
    }
    final restored = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final integrity = restored.select('PRAGMA integrity_check').first.columnAt(0);
      if (integrity != 'ok') report.problems.add('Datenbank: $integrity');
    } finally {
      restored.close();
    }
    final actual = _counts(path);
    report.documents = actual['documents'] ?? 0;
    for (final MapEntry(key: table, value: n) in counts.entries) {
      if (actual[table] != n) report.problems.add('Tabelle $table: ${actual[table]} statt $n Einträge');
    }
    for (final key in _mediaKeys(path)) {
      if (!names.contains('media/$key')) report.problems.add('media/$key fehlt im Archiv');
    }
  }
}

/// SHA-256 und Größe, während die Daten vorbeilaufen.
class _Digest {
  final _output = _DigestSink();
  late final _input = sha256.startChunkedConversion(_output);
  int size = 0;

  void add(List<int> chunk) {
    size += chunk.length;
    _input.add(chunk);
  }

  String close() {
    _input.close();
    return _output.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
