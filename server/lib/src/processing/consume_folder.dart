import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'consumer.dart';

final _log = Logger('consume_folder');

/// Überwacht den Eingangsordner per Polling.
///
/// Polling statt Dateisystem-Events, weil Events über SMB/NFS unzuverlässig
/// sind. Eine Datei gilt erst als fertig, wenn Größe und Änderungszeit
/// über zwei Durchläufe gleich bleiben (Scanner schreiben oft langsam).
class ConsumeFolderWatcher {
  ConsumeFolderWatcher(this.directory, this.consumer, {required this.interval});

  final String directory;
  final Consumer consumer;
  final Duration interval;

  Timer? _timer;
  bool _scanning = false;
  final _lastSeen = <String, (int, DateTime)>{};

  void start() {
    Directory(directory).createSync(recursive: true);
    _log.info('Überwache $directory alle ${interval.inSeconds}s');
    _timer = Timer.periodic(interval, (_) => scan());
  }

  void stop() => _timer?.cancel();

  static bool _ignored(String path) {
    final name = p.basename(path);
    return name.startsWith('.') ||
        name.startsWith('~') ||
        name.endsWith('.tmp') ||
        name.endsWith('.part') ||
        name == 'Thumbs.db' ||
        name == 'desktop.ini';
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final current = <String>{};
      await for (final entity in Directory(
        directory,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File || _ignored(entity.path)) continue;
        if (p
            .split(p.relative(entity.path, from: directory))
            .any((part) => part.startsWith('.'))) {
          continue;
        }
        current.add(entity.path);
        final stat = await entity.stat();
        final signature = (stat.size, stat.modified);
        if (_lastSeen[entity.path] != signature) {
          _lastSeen[entity.path] = signature;
          continue;
        }
        _lastSeen.remove(entity.path);
        current.remove(entity.path);
        _log.info('Neue Datei: ${entity.path}');
        await consumer.submit(
          entity,
          originalName: p.basename(entity.path),
          moveSource: true,
        );
      }
      _lastSeen.removeWhere((path, _) => !current.contains(path));
    } catch (e, st) {
      _log.warning('Fehler beim Durchsuchen von $directory', e, st);
    } finally {
      _scanning = false;
    }
  }
}
