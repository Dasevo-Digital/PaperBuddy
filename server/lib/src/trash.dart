import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

import 'access.dart';
import 'storage.dart';

final _log = Logger('trash');

/// Papierkorb: gelöschte Dokumente bleiben [delay] lang wiederherstellbar.
class Trash {
  Trash(this.db, this.store, this.access, {required this.delay});

  final Database db;
  final BlobStore store;
  final Access access;
  final Duration delay;
  Timer? _timer;

  void moveToTrash(List<int> ids) {
    if (ids.isEmpty) return;
    db.execute(
      'UPDATE documents SET deleted_at = ? WHERE id IN (${ids.join(',')}) AND deleted_at IS NULL',
      [DateTime.now().toUtc().toIso8601String()],
    );
  }

  void restore(List<int> ids) {
    if (ids.isEmpty) return;
    db.execute('UPDATE documents SET deleted_at = NULL WHERE id IN (${ids.join(',')})');
  }

  /// Endgültig löschen, samt Dateien und Freigaben.
  Future<void> purge(List<int> ids) async {
    for (final id in ids) {
      final row = db.select(
        'SELECT original_path, archive_path, thumbnail_path FROM documents WHERE id = ?',
        [id],
      ).firstOrNull;
      if (row == null) continue;
      db.execute('DELETE FROM documents WHERE id = ?', [id]);
      access.forgetObject('document', id);
      for (final key in [row['original_path'], row['archive_path'], row['thumbnail_path']]) {
        if (key is String && key.isNotEmpty) {
          try {
            await store.delete(key);
          } catch (e) {
            _log.warning('Datei $key nicht gelöscht: $e');
          }
        }
      }
    }
  }

  /// Leert Dokumente, die länger als [delay] im Papierkorb liegen.
  Future<int> emptyExpired() async {
    final cutoff = DateTime.now().toUtc().subtract(delay).toIso8601String();
    final ids = [
      for (final r in db.select(
        'SELECT id FROM documents WHERE deleted_at IS NOT NULL AND deleted_at < ?',
        [cutoff],
      ))
        r['id'] as int,
    ];
    await purge(ids);
    if (ids.isNotEmpty) _log.info('${ids.length} Dokument(e) endgültig aus dem Papierkorb gelöscht');
    return ids.length;
  }

  void startAutoEmpty() {
    _timer = Timer.periodic(const Duration(hours: 6), (_) => emptyExpired());
    emptyExpired();
  }

  void stop() => _timer?.cancel();
}
