import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

final _log = Logger('access_log');

/// Wer hat wann ein Dokument angesehen, heruntergeladen oder über einen
/// Freigabelink abgerufen (PaperBuddy-Erweiterung, getrennt vom
/// Paperless-Verlauf unter `/history/`).
///
/// Wiederholte Zugriffe derselben Person auf dasselbe Dokument zählen
/// innerhalb von [repeatWindow] nur einmal, damit Aktualisieren nicht jede
/// Zeile füllt. Die Adresse wird nur bei Freigabelinks gespeichert; sonst
/// genügt der Benutzer.
class AccessLog {
  AccessLog(this.db, {this.enabled = true, this.retention = const Duration(days: 90)});

  final Database db;
  final bool enabled;

  /// So lange bleiben Einträge; ältere entfernt [prune].
  final Duration retention;

  static const repeatWindow = Duration(minutes: 10);
  static const actions = {'view', 'download', 'share'};

  Timer? _timer;

  void record(int documentId, String action, {int? userId, int? shareLinkId, String? address, DateTime? now}) {
    if (!enabled) return;
    assert(actions.contains(action));
    final t = now ?? DateTime.now();
    final since = t.subtract(repeatWindow).toUtc().toIso8601String();
    final recent = db.select(
      'SELECT 1 FROM document_access WHERE document_id = ? AND action = ? AND timestamp > ? '
      'AND user_id IS ? AND share_link_id IS ? AND address IS ? LIMIT 1',
      [documentId, action, since, userId, shareLinkId, shareLinkId == null ? null : address],
    );
    if (recent.isNotEmpty) return;
    db.execute(
      'INSERT INTO document_access (document_id, timestamp, action, user_id, share_link_id, address) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [documentId, t.toUtc().toIso8601String(), action, userId, shareLinkId, shareLinkId == null ? null : address],
    );
  }

  /// Neueste zuerst, im Stil des Paperless-Verlaufs (`actor`).
  List<Map<String, Object?>> entries(int documentId) => [
    for (final r in db.select(
      'SELECT a.*, u.username FROM document_access a LEFT JOIN users u ON u.id = a.user_id '
      'WHERE a.document_id = ? ORDER BY a.timestamp DESC, a.id DESC',
      [documentId],
    ))
      {
        'id': r['id'],
        'timestamp': r['timestamp'],
        'action': r['action'],
        'actor': r['user_id'] == null ? null : {'id': r['user_id'], 'username': r['username']},
        'share_link': r['share_link_id'],
        'address': r['address'],
      },
  ];

  /// Entfernt Einträge, die älter als [retention] sind; liefert die Anzahl.
  int prune({DateTime? now}) {
    final before = (now ?? DateTime.now()).subtract(retention).toUtc().toIso8601String();
    db.execute('DELETE FROM document_access WHERE timestamp < ?', [before]);
    return db.updatedRows;
  }

  void start() {
    void run() {
      final n = prune();
      if (n > 0) _log.info('$n alte Zugriffe entfernt');
    }

    run();
    _timer = Timer.periodic(const Duration(hours: 24), (_) => run());
  }

  void stop() => _timer?.cancel();
}
