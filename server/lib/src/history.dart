import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'db.dart';

/// Änderungsverlauf je Dokument, im Format von `/api/documents/<id>/history/`
/// in Paperless-ngx (django-auditlog).
class History {
  History(this.db);
  final Database db;

  static const _fields = {
    'title': 'title',
    'correspondent_id': 'correspondent',
    'document_type_id': 'document_type',
    'storage_path_id': 'storage_path',
    'created': 'created',
    'archive_serial_number': 'archive_serial_number',
    'owner': 'owner',
    'checksum': 'checksum',
    'original_filename': 'original_filename',
  };

  /// Zustand der verfolgten Felder, Tags und Custom Fields.
  Map<String, Object?>? snapshot(int id) {
    final d = db.select('SELECT * FROM documents WHERE id = ?', [id]).firstOrNull;
    if (d == null) return null;
    return {
      for (final e in _fields.entries) e.value: d[e.key],
      'deleted_at': d['deleted_at'],
      'content_length': (d['content'] as String).length,
      'tags': {
        for (final r in db.select(
            'SELECT t.name FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = ?', [id]))
          r['name'] as String,
      },
      'custom_fields': {
        for (final r in db.select(
            'SELECT c.name, f.value FROM document_custom_fields f JOIN custom_fields c ON c.id = f.field_id '
            'WHERE f.document_id = ?',
            [id]))
          r['name'] as String: r['value'],
      },
    };
  }

  void recordCreate(int id, {int? actor}) {
    final s = snapshot(id);
    if (s == null) return;
    _insert(id, 'create', {
      for (final e in s.entries)
        if (e.key != 'tags' && e.key != 'custom_fields' && e.key != 'deleted_at' && e.key != 'content_length' && e.value != null)
          e.key: [null, '${e.value}'],
      if ((s['tags'] as Set).isNotEmpty)
        'tags': {'type': 'm2m', 'operation': 'add', 'objects': (s['tags'] as Set).toList()},
    }, actor);
  }

  /// Vergleicht mit [before] und legt bei Unterschieden einen Eintrag an.
  void recordUpdate(int id, Map<String, Object?>? before, {int? actor, String? note}) {
    if (before == null) return;
    final after = snapshot(id);
    if (after == null) return;
    final changes = <String, Object?>{};
    for (final key in [..._fields.values, 'deleted_at']) {
      if ('${before[key]}' != '${after[key]}') {
        changes[key] = [before[key]?.toString(), after[key]?.toString()];
      }
    }
    if (before['content_length'] != after['content_length']) {
      changes['content'] = ['${before['content_length']} Zeichen', '${after['content_length']} Zeichen'];
    }
    final oldTags = before['tags'] as Set, newTags = after['tags'] as Set;
    final added = newTags.difference(oldTags), removed = oldTags.difference(newTags);
    if (added.isNotEmpty) changes['tags'] = {'type': 'm2m', 'operation': 'add', 'objects': added.toList()};
    if (removed.isNotEmpty) {
      changes[added.isNotEmpty ? 'tags_removed' : 'tags'] = {'type': 'm2m', 'operation': 'remove', 'objects': removed.toList()};
    }
    final oldFields = before['custom_fields'] as Map, newFields = after['custom_fields'] as Map;
    for (final name in {...oldFields.keys, ...newFields.keys}) {
      if ('${oldFields[name]}' != '${newFields[name]}') {
        changes['custom_field:$name'] = [_plain(oldFields[name]), _plain(newFields[name])];
      }
    }
    if (note != null) changes['version'] = [null, note];
    if (changes.isEmpty) return;
    _insert(id, 'update', changes, actor);
  }

  static String? _plain(Object? json) => json == null ? null : '${jsonDecode(json as String)}';

  void _insert(int id, String action, Map<String, Object?> changes, int? actor) => db.execute(
        'INSERT INTO document_history (document_id, timestamp, action, changes, actor_id) VALUES (?, ?, ?, ?, ?)',
        [id, nowIso(), action, jsonEncode(changes), actor],
      );

  List<Map<String, dynamic>> entries(int id) => [
        for (final r in db.select(
          'SELECT h.*, u.username FROM document_history h LEFT JOIN users u ON u.id = h.actor_id '
          'WHERE h.document_id = ? ORDER BY h.timestamp DESC, h.id DESC',
          [id],
        ))
          {
            'id': r['id'],
            'timestamp': r['timestamp'],
            'action': r['action'],
            'changes': jsonDecode(r['changes'] as String),
            'actor': r['actor_id'] == null ? null : {'id': r['actor_id'], 'username': r['username']},
          },
      ];
}
