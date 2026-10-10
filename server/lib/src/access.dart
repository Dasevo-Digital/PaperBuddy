import 'package:sqlite3/sqlite3.dart';

import 'api/http_utils.dart';
import 'auth.dart';

/// Modelle, für die es Rechte gibt (wie in Paperless-ngx: `view_document`,
/// `add_tag`, `change_customfield` …).
const allModels = [
  'document',
  'tag',
  'correspondent',
  'documenttype',
  'storagepath',
  'savedview',
  'paperlesstask',
  'uisettings',
  'note',
  'customfield',
  'sharelink',
  'workflow',
  'mailaccount',
  'mailrule',
  'user',
  'group',
  'history',
  'appconfig',
];

const allActions = ['view', 'add', 'change', 'delete'];

final allPermissions = [
  for (final m in allModels)
    for (final a in allActions) '${a}_$m',
];

/// Rechte, mit denen ein normaler Benutzer seine Dokumente verwalten kann.
final defaultUserPermissions = [
  for (final m in [
    'document',
    'tag',
    'correspondent',
    'documenttype',
    'storagepath',
    'savedview',
    'note',
    'customfield',
    'uisettings',
    'sharelink',
  ])
    for (final a in allActions) '${a}_$m',
  'view_paperlesstask',
  'change_paperlesstask',
];

/// Modell- und Objektrechte.
///
/// Wie in Paperless-ngx: Ein Objekt ohne Eigentümer sehen alle mit dem
/// passenden Modellrecht; sonst der Eigentümer, Superuser und wer per
/// Objektrecht freigegeben ist. „Ändern“ schließt „Ansehen“ ein.
class Access {
  Access(this.db);
  final Database db;

  List<int> groupIds(User u) => [
        for (final r in db.select('SELECT group_id FROM user_groups WHERE user_id = ?', [u.id]))
          r['group_id'] as int,
      ];

  Set<String> permissions(User u) {
    if (u.isSuperuser) return allPermissions.toSet();
    return {
      for (final r in db.select(
        'SELECT permission FROM user_permissions WHERE user_id = ? '
        'UNION SELECT gp.permission FROM group_permissions gp '
        'JOIN user_groups ug ON ug.group_id = gp.group_id WHERE ug.user_id = ?',
        [u.id, u.id],
      ))
        r['permission'] as String,
    };
  }

  bool has(User u, String action, String model) {
    // Integrations-Token lesen nur.
    if (u.scope != null && action != 'view') return false;
    return u.isSuperuser || permissions(u).contains('${action}_$model');
  }

  void require(User u, String action, String model) {
    if (!has(u, action, model)) throw forbidden();
  }

  static ApiError forbidden() =>
      ApiError(403, 'You do not have permission to perform this action.');

  String _sharedWith(User u, String type, String alias, List<String> perms) {
    final groups = groupIds(u);
    final groupSql = groups.isEmpty ? '' : ' OR op.group_id IN (${groups.join(',')})';
    return 'EXISTS (SELECT 1 FROM object_permissions op WHERE op.object_type = \'$type\' '
        'AND op.object_id = $alias.id AND op.permission IN (${perms.map((p) => "'$p'").join(',')}) '
        'AND (op.user_id = ${u.id}$groupSql))';
  }

  /// SQL-Bedingung für sichtbare Objekte (nur Ganzzahlen eingesetzt).
  String visibleSql(User u, String type, String alias) {
    final scope = u.scope;
    final tagged = scope != null && type == 'document'
        ? ' AND $alias.id IN (SELECT document_id FROM document_tags WHERE tag_id = ${scope.tagId})'
        : '';
    if (u.isSuperuser) return '(1 = 1$tagged)';
    return '(($alias.owner IS NULL OR $alias.owner = ${u.id} OR '
        '${_sharedWith(u, type, alias, ['view', 'change'])})$tagged)';
  }

  /// SQL-Bedingung für änderbare Objekte.
  String changeableSql(User u, String type, String alias) {
    if (u.scope != null) return '0 = 1';
    if (u.isSuperuser) return '1 = 1';
    return '($alias.owner IS NULL OR $alias.owner = ${u.id} OR '
        '${_sharedWith(u, type, alias, ['change'])})';
  }

  bool canView(User u, String type, int id, int? owner) {
    final scope = u.scope;
    if (scope != null &&
        type == 'document' &&
        db.select('SELECT 1 FROM document_tags WHERE document_id = ? AND tag_id = ?', [id, scope.tagId]).isEmpty) {
      return false;
    }
    return u.isSuperuser || owner == null || owner == u.id || _hasObjectPerm(u, type, id, const ['view', 'change']);
  }

  bool canChange(User u, String type, int id, int? owner) =>
      u.scope == null &&
      (u.isSuperuser || owner == null || owner == u.id || _hasObjectPerm(u, type, id, const ['change']));

  bool _hasObjectPerm(User u, String type, int id, List<String> perms) {
    final groups = groupIds(u);
    return db.select(
      'SELECT 1 FROM object_permissions WHERE object_type = ? AND object_id = ? '
      'AND permission IN (${perms.map((_) => '?').join(',')}) '
      'AND (user_id = ?${groups.isEmpty ? '' : ' OR group_id IN (${groups.join(',')})'}) LIMIT 1',
      [type, id, ...perms, u.id],
    ).isNotEmpty;
  }

  /// `{"view": {"users": [], "groups": []}, "change": {…}}`
  Map<String, dynamic> permissionsJson(String type, int id) {
    final out = {
      'view': {'users': <int>[], 'groups': <int>[]},
      'change': {'users': <int>[], 'groups': <int>[]},
    };
    for (final r in db.select(
      'SELECT permission, user_id, group_id FROM object_permissions '
      'WHERE object_type = ? AND object_id = ? ORDER BY user_id, group_id',
      [type, id],
    )) {
      final bucket = out[r['permission'] as String]!;
      if (r['user_id'] != null) bucket['users']!.add(r['user_id'] as int);
      if (r['group_id'] != null) bucket['groups']!.add(r['group_id'] as int);
    }
    return out;
  }

  bool hasShares(String type, int id) => db.select(
        'SELECT 1 FROM object_permissions WHERE object_type = ? AND object_id = ? LIMIT 1',
        [type, id],
      ).isNotEmpty;

  /// Übernimmt `set_permissions` aus einem Request-Body.
  /// Mit [merge] werden vorhandene Freigaben ergänzt statt ersetzt.
  void setPermissions(String type, int id, Object? spec, {bool merge = false}) {
    if (spec is! Map) return;
    if (!merge) {
      db.execute('DELETE FROM object_permissions WHERE object_type = ? AND object_id = ?', [type, id]);
    }
    for (final perm in ['view', 'change']) {
      final bucket = spec[perm];
      if (bucket is! Map) continue;
      for (final (column, ids) in [
        ('user_id', asIntList(bucket['users'])),
        ('group_id', asIntList(bucket['groups'])),
      ]) {
        for (final target in ids) {
          final exists = db.select(
            'SELECT 1 FROM object_permissions WHERE object_type = ? AND object_id = ? '
            'AND permission = ? AND $column = ?',
            [type, id, perm, target],
          ).isNotEmpty;
          if (!exists) {
            db.execute(
              'INSERT INTO object_permissions (object_type, object_id, permission, $column) '
              'VALUES (?, ?, ?, ?)',
              [type, id, perm, target],
            );
          }
        }
      }
    }
  }

  void forgetObject(String type, int id) =>
      db.execute('DELETE FROM object_permissions WHERE object_type = ? AND object_id = ?', [type, id]);
}
