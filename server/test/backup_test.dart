import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:paperbuddy_server/src/backup/age.dart';
import 'package:paperbuddy_server/src/backup/byte_reader.dart';
import 'package:paperbuddy_server/src/backup/tar.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Kleiner Arbeitsfaktor, damit die Tests schnell bleiben.
const _fast = 10;

Future<Uint8List> _encrypt(Directory dir, List<int> plain, String passphrase) async {
  final file = File(p.join(dir.path, 'x.age'));
  final out = await file.open(mode: FileMode.write);
  final w = await Age.writer(out, passphrase, workFactor: _fast);
  // In ungleichen Stücken, wie beim Schreiben eines Archivs.
  for (var i = 0; i < plain.length; i += 7000) {
    await w.add(plain.sublist(i, i + 7000 > plain.length ? plain.length : i + 7000));
  }
  await w.close();
  await out.close();
  return file.readAsBytes();
}

Future<List<int>> _decrypt(List<int> data, String passphrase) async =>
    (await Age.decrypt(Stream.value(data), passphrase).toList()).expand((c) => c).toList();

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('paperbuddy-backup-test-'));
  tearDown(() => tmp.delete(recursive: true));

  group('age', () {
    test('hin und zurück, auch an Blockgrenzen', () async {
      for (final size in [0, 1, Age.chunkSize, Age.chunkSize + 1, 3 * Age.chunkSize + 123]) {
        final plain = List.generate(size, (i) => i * 31 % 251);
        final data = await _encrypt(tmp, plain, 'richtig-langes-passwort');
        expect(utf8.decode(data.sublist(0, 22)), 'age-encryption.org/v1\n');
        expect(await _decrypt(data, 'richtig-langes-passwort'), plain, reason: 'Größe $size');
      }
    });

    test('falsche Passphrase, veränderte und abgeschnittene Daten', () async {
      final plain = List.generate(2 * Age.chunkSize + 10, (i) => i % 256);
      final data = await _encrypt(tmp, plain, 'geheim-geheim');
      await expectLater(_decrypt(data, 'falsch-falsch'), throwsA(isA<AgeException>()));

      final flipped = Uint8List.fromList(data)..[data.length - 40] ^= 1;
      await expectLater(_decrypt(flipped, 'geheim-geheim'), throwsA(isA<AgeException>()));

      // Ohne den letzten Block: der vorletzte trägt keine Schlussmarke.
      final cut = data.sublist(0, data.length - 26);
      await expectLater(_decrypt(cut, 'geheim-geheim'), throwsA(isA<AgeException>()));

      final header = Uint8List.fromList(data)..[30] ^= 1;
      await expectLater(_decrypt(header, 'geheim-geheim'), throwsA(isA<AgeException>()));
    });
  });

  test('tar mit langen und nicht-ASCII-Namen', () async {
    final out = BytesBuilder();
    final tar = TarWriter((b) async => out.add(b));
    final long = 'media/${'Ordner/' * 20}Stromrechnung Müller.pdf';
    final file = File(p.join(tmp.path, 'a.bin'))..writeAsBytesSync(List.generate(1000, (i) => i % 256));
    await tar.addFile(long, file);
    await tar.addBytes('kurz.txt', utf8.encode('Hallo'));
    await tar.close();

    final read = <String, List<int>>{};
    await TarReader(ByteReader(Stream.value(out.takeBytes()))).forEach((name, size, data) async {
      final bytes = <int>[];
      await data((c) => bytes.addAll(c));
      read[name] = bytes;
    });
    expect(read.keys, [long, 'kurz.txt']);
    expect(read[long], file.readAsBytesSync());
    expect(utf8.decode(read['kurz.txt']!), 'Hallo');
  });

  group('Sicherung', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    BackupService service({BackupSettings? settings}) => BackupService(
      db: env.server.db,
      store: env.server.store,
      workDir: p.join(tmp.path, 'work'),
      settings: settings,
      statusFile: p.join(tmp.path, 'status.json'),
    );

    test('sichern, prüfen und in einen leeren Ordner wiederherstellen', () async {
      final a = await env.uploadText('vertrag.txt', 'Mietvertrag Wohnung Lindenhof');
      await env.uploadText('rechnung.txt', 'Stromrechnung Stadtwerke');
      await env.json('POST', '/api/reminders/', status: 201, body: {'document': a, 'due': '2026-11-30', 'note': 'Kündigen'});

      final backups = service();
      final created = await backups.create(p.join(tmp.path, 'ziel'), 'lange-passphrase', workFactor: _fast);
      expect(created.ok, isTrue, reason: created.problems.join('; '));
      expect(p.basename(created.file), matches(RegExp(r'^paperbuddy-\d{8}-\d{6}\.tar\.age$')));
      expect(created.documents, 2);

      final checked = await backups.verify(created.file, 'lange-passphrase');
      expect(checked.ok, isTrue, reason: checked.problems.join('; '));
      expect(checked.files, created.files);

      final wrong = await backups.verify(created.file, 'andere-passphrase');
      expect(wrong.problems, ['Falsche Passphrase']);

      final target = p.join(tmp.path, 'wiederhergestellt');
      final restored = await backups.restore(created.file, 'lange-passphrase', target);
      expect(restored.ok, isTrue, reason: restored.problems.join('; '));
      final db = sqlite3.open(p.join(target, 'paperbuddy.sqlite3'));
      addTearDown(db.close);
      expect(db.select('SELECT COUNT(*) AS n FROM documents').first['n'], 2);
      expect(db.select('SELECT note FROM reminders').first['note'], 'Kündigen');
      for (final r in db.select('SELECT original_path FROM documents')) {
        expect(File(p.join(target, 'media', r['original_path'] as String)).existsSync(), isTrue);
      }
      // Nie über vorhandene Daten.
      await expectLater(backups.restore(created.file, 'lange-passphrase', target), throwsStateError);
    });

    test('fehlende Datei im Speicher wird gemeldet', () async {
      final id = await env.uploadText('weg.txt', 'Diese Datei verschwindet');
      final key = env.server.db.select('SELECT original_path FROM documents WHERE id = ?', [id]).first['original_path'];
      await env.server.store.delete(key as String);
      final backups = service();
      final created = await backups.create(p.join(tmp.path, 'ziel'), 'lange-passphrase', workFactor: _fast);
      expect(created.problems, ['1 Datei(en) fehlen im Speicher']);
      final checked = await backups.verify(created.file, 'lange-passphrase');
      expect(checked.problems, contains('media/$key fehlte schon beim Sichern'));
    });

    test('zeitgesteuert: Ergebnis merken und nur die neuesten behalten', () async {
      await env.uploadText('a.txt', 'Erstes Dokument');
      final dir = p.join(tmp.path, 'sicherungen');
      Directory(dir).createSync();
      for (final old in ['paperbuddy-20260101-030000.tar.age', 'paperbuddy-20260102-030000.tar.age', 'fremd.tar.age']) {
        File(p.join(dir, old)).writeAsStringSync('alt');
      }
      final backups = service(settings: BackupSettings(dir: dir, passphrase: 'lange-passphrase', keep: 2));
      final report = await backups.runScheduled();
      expect(report!.ok, isTrue, reason: report.problems.join('; '));
      final left = Directory(dir).listSync().map((f) => p.basename(f.path)).toList()..sort();
      expect(left, ['fremd.tar.age', 'paperbuddy-20260102-030000.tar.age', p.basename(report.file)]);
      expect(backups.lastStatus!['ok'], isTrue);
      expect(backups.lastStatus!['documents'], 1);
    });
  });
}
