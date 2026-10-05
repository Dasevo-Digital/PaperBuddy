import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../auth.dart';
import '../db.dart';
import '../totp.dart';
import 'http_utils.dart';

/// `/api/users/`, `/api/groups/` und `/api/profile/`.
class UsersResource {
  UsersResource(this.db, this.auth, this.access);
  final Database db;
  final AuthService auth;
  final Access access;

  static const _maskedPassword = '**********';

  List<String> _userPerms(int id) => [
        for (final r in db.select('SELECT permission FROM user_permissions WHERE user_id = ? ORDER BY permission', [id]))
          r['permission'] as String,
      ];

  List<int> _userGroups(int id) => [
        for (final r in db.select('SELECT group_id FROM user_groups WHERE user_id = ? ORDER BY group_id', [id]))
          r['group_id'] as int,
      ];

  List<String> _groupPerms(int id) => [
        for (final r in db.select('SELECT permission FROM group_permissions WHERE group_id = ? ORDER BY permission', [id]))
          r['permission'] as String,
      ];

  Map<String, dynamic> serializeUser(Row u) {
    final id = u['id'] as int;
    final inherited = <String>{
      for (final r in db.select(
        'SELECT gp.permission FROM group_permissions gp JOIN user_groups ug ON ug.group_id = gp.group_id '
        'WHERE ug.user_id = ?',
        [id],
      ))
        r['permission'] as String,
    }.toList()
      ..sort();
    return {
      'id': id,
      'username': u['username'],
      'email': u['email'],
      'password': _maskedPassword,
      'first_name': u['first_name'],
      'last_name': u['last_name'],
      'date_joined': u['date_joined'],
      'is_staff': u['is_staff'] == 1,
      'is_active': u['is_active'] == 1,
      'is_superuser': u['is_superuser'] == 1,
      'groups': _userGroups(id),
      'user_permissions': _userPerms(id),
      'inherited_permissions': inherited,
      'is_mfa_enabled': u['totp_secret'] != null,
    };
  }

  Row? _user(int id) => db.select('SELECT * FROM users WHERE id = ?', [id]).firstOrNull;
  User _me(Request r) => r.context['user'] as User;

  Response listUsers(Request request) {
    access.require(_me(request), 'view', 'user');
    final q = request.url.queryParameters;
    final where = <String>['1 = 1'];
    final args = <Object?>[];
    final name = q['username__icontains'];
    if (name != null && name.isNotEmpty) {
      where.add('username LIKE ?');
      args.add('%$name%');
    }
    final ids = asIntList(q['id__in']);
    if (ids.isNotEmpty) where.add('id IN (${ids.join(',')})');
    final rows = db.select('SELECT * FROM users WHERE ${where.join(' AND ')} ORDER BY username COLLATE NOCASE', args);
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) serializeUser(r)],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  Response getUser(Request request) {
    access.require(_me(request), 'view', 'user');
    final row = _user(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    return json(serializeUser(row));
  }

  Future<Response> createUser(Request request) async {
    final me = _me(request);
    access.require(me, 'add', 'user');
    final body = await readBody(request);
    final username = body['username']?.toString().trim() ?? '';
    if (username.isEmpty) throw ApiError.badRequest({'username': ['This field is required.']});
    if (asBool(body['is_superuser']) && !me.isSuperuser) {
      throw ApiError(403, 'Superuser status can only be granted by a superuser.');
    }
    final password = body['password']?.toString();
    final hash = (password == null || password.isEmpty || password == _maskedPassword)
        ? '!' // nicht nutzbares Passwort, wie bei Django
        : await auth.hashPassword(password);
    try {
      db.execute(
        'INSERT INTO users (username, password_hash, first_name, last_name, email, is_superuser, '
        'is_staff, is_active, date_joined) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          username,
          hash,
          body['first_name']?.toString() ?? '',
          body['last_name']?.toString() ?? '',
          body['email']?.toString() ?? '',
          asBool(body['is_superuser']) ? 1 : 0,
          asBool(body['is_staff']) ? 1 : 0,
          body.containsKey('is_active') ? (asBool(body['is_active']) ? 1 : 0) : 1,
          nowIso(),
        ],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) {
        throw ApiError.badRequest({'username': ['A user with that username already exists.']});
      }
      rethrow;
    }
    final id = db.lastInsertRowId;
    _setUserRelations(id, body);
    return json(serializeUser(_user(id)!), status: 201);
  }

  Future<Response> updateUser(Request request) async {
    final me = _me(request);
    access.require(me, 'change', 'user');
    final row = _user(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    final id = row['id'] as int;
    final body = await readBody(request);
    // Superuser dürfen nur von Superusern bearbeitet oder ernannt werden.
    if (!me.isSuperuser && (row['is_superuser'] == 1 || asBool(body['is_superuser']))) {
      throw Access.forbidden();
    }
    final values = <String, Object?>{};
    void put(String key, Object? Function(Object?) convert) {
      if (body.containsKey(key)) values[key] = convert(body[key]);
    }

    put('username', (v) => v?.toString().trim());
    put('first_name', (v) => v?.toString() ?? '');
    put('last_name', (v) => v?.toString() ?? '');
    put('email', (v) => v?.toString() ?? '');
    put('is_active', (v) => asBool(v) ? 1 : 0);
    put('is_staff', (v) => asBool(v) ? 1 : 0);
    put('is_superuser', (v) => asBool(v) ? 1 : 0);
    if (id == me.id) {
      // Sich selbst nicht aussperren.
      values.remove('is_active');
      values.remove('is_superuser');
    }
    if (values.isNotEmpty) {
      final cols = values.keys.toList();
      try {
        db.execute('UPDATE users SET ${cols.map((c) => '$c = ?').join(', ')} WHERE id = ?',
            [for (final c in cols) values[c], id]);
      } on SqliteException catch (e) {
        if (e.extendedResultCode == 2067) {
          throw ApiError.badRequest({'username': ['A user with that username already exists.']});
        }
        rethrow;
      }
    }
    final password = body['password']?.toString();
    if (password != null && password.isNotEmpty && password != _maskedPassword) {
      await auth.setPassword(id, password);
    }
    _setUserRelations(id, body);
    return json(serializeUser(_user(id)!));
  }

  void _setUserRelations(int id, Map<String, dynamic> body) {
    if (body.containsKey('groups')) {
      db.execute('DELETE FROM user_groups WHERE user_id = ?', [id]);
      for (final g in asIntList(body['groups'])) {
        db.execute('INSERT OR IGNORE INTO user_groups (user_id, group_id) SELECT ?, id FROM groups WHERE id = ?', [id, g]);
      }
    }
    if (body.containsKey('user_permissions')) {
      db.execute('DELETE FROM user_permissions WHERE user_id = ?', [id]);
      for (final p in _validPermissions(body['user_permissions'])) {
        db.execute('INSERT INTO user_permissions (user_id, permission) VALUES (?, ?)', [id, p]);
      }
    }
  }

  Set<String> _validPermissions(Object? raw) {
    final list = raw is List ? raw.map((e) => '$e') : const <String>[];
    final valid = allPermissions.toSet();
    final unknown = list.where((p) => !valid.contains(p)).toList();
    if (unknown.isNotEmpty) {
      throw ApiError.badRequest({'permissions': ['Unknown permission(s): ${unknown.join(', ')}']});
    }
    return list.toSet();
  }

  Response deleteUser(Request request) {
    final me = _me(request);
    access.require(me, 'delete', 'user');
    final row = _user(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    if (row['id'] == me.id) throw ApiError.badRequest({'detail': 'You cannot delete yourself.'});
    if (row['is_superuser'] == 1 && !me.isSuperuser) throw Access.forbidden();
    db.execute('DELETE FROM users WHERE id = ?', [row['id']]);
    return Response(204);
  }

  // Gruppen ------------------------------------------------------------------

  Map<String, dynamic> serializeGroup(Row g) => {
        'id': g['id'],
        'name': g['name'],
        'permissions': _groupPerms(g['id'] as int),
      };

  Response listGroups(Request request) {
    access.require(_me(request), 'view', 'group');
    final rows = db.select('SELECT * FROM groups ORDER BY name COLLATE NOCASE');
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) serializeGroup(r)],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  Row _group(Request request) =>
      db.select('SELECT * FROM groups WHERE id = ?', [int.parse(request.params['id']!)]).firstOrNull ??
      (throw ApiError(404, 'Not found.'));

  Response getGroup(Request request) {
    access.require(_me(request), 'view', 'group');
    return json(serializeGroup(_group(request)));
  }

  Future<Response> createGroup(Request request) async {
    access.require(_me(request), 'add', 'group');
    final body = await readBody(request);
    final name = body['name']?.toString().trim() ?? '';
    if (name.isEmpty) throw ApiError.badRequest({'name': ['This field is required.']});
    final perms = _validPermissions(body['permissions']);
    try {
      db.execute('INSERT INTO groups (name) VALUES (?)', [name]);
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) throw ApiError.badRequest({'name': ['Group with this name already exists.']});
      rethrow;
    }
    final id = db.lastInsertRowId;
    for (final p in perms) {
      db.execute('INSERT INTO group_permissions (group_id, permission) VALUES (?, ?)', [id, p]);
    }
    return json(serializeGroup(db.select('SELECT * FROM groups WHERE id = ?', [id]).first), status: 201);
  }

  Future<Response> updateGroup(Request request) async {
    access.require(_me(request), 'change', 'group');
    final group = _group(request);
    final id = group['id'] as int;
    final body = await readBody(request);
    final name = body['name']?.toString().trim();
    if (name != null && name.isNotEmpty) {
      try {
        db.execute('UPDATE groups SET name = ? WHERE id = ?', [name, id]);
      } on SqliteException catch (e) {
        if (e.extendedResultCode == 2067) throw ApiError.badRequest({'name': ['Group with this name already exists.']});
        rethrow;
      }
    }
    if (body.containsKey('permissions')) {
      final perms = _validPermissions(body['permissions']);
      db.execute('DELETE FROM group_permissions WHERE group_id = ?', [id]);
      for (final p in perms) {
        db.execute('INSERT INTO group_permissions (group_id, permission) VALUES (?, ?)', [id, p]);
      }
    }
    return json(serializeGroup(db.select('SELECT * FROM groups WHERE id = ?', [id]).first));
  }

  Response deleteGroup(Request request) {
    access.require(_me(request), 'delete', 'group');
    final group = _group(request);
    db.execute('DELETE FROM groups WHERE id = ?', [group['id']]);
    db.execute('DELETE FROM object_permissions WHERE group_id = ?', [group['id']]);
    return Response(204);
  }

  // Profil -------------------------------------------------------------------

  Response profile(Request request) {
    final me = _me(request);
    final row = _user(me.id)!;
    return json({
      'email': row['email'],
      'password': _maskedPassword,
      'first_name': row['first_name'],
      'last_name': row['last_name'],
      'auth_token': auth.tokenFor(me),
      'social_accounts': <Object>[],
      'has_usable_password': row['password_hash'] != '!',
      'is_mfa_enabled': row['totp_secret'] != null,
    });
  }

  Future<Response> updateProfile(Request request) async {
    final me = _me(request);
    final body = await readBody(request);
    for (final key in ['email', 'first_name', 'last_name']) {
      if (body.containsKey(key)) {
        db.execute('UPDATE users SET $key = ? WHERE id = ?', [body[key]?.toString() ?? '', me.id]);
      }
    }
    final password = body['password']?.toString();
    if (password != null && password.isNotEmpty && password != _maskedPassword) {
      await auth.setPassword(me.id, password);
    }
    return profile(request);
  }

  Response generateToken(Request request) => json(auth.regenerateToken(_me(request)));

  // Zwei-Faktor-Anmeldung (wie Paperless-ngx `/api/profile/totp/`) ------------

  /// Neuer Schlüssel zum Einrichten; aktiv wird er erst mit `POST` und einem
  /// passenden Code.
  Response totpSetup(Request request) {
    final me = _me(request);
    final secret = Totp.newSecret();
    final url = Totp.uri(secret, account: me.username);
    return json({'url': url, 'qr_svg': _qrSvg(url), 'secret': secret});
  }

  Future<Response> totpActivate(Request request) async {
    final me = _me(request);
    final body = await readBody(request);
    final secret = body['secret']?.toString() ?? '';
    final code = body['code']?.toString() ?? '';
    final codes = secret.isEmpty ? null : auth.enableTotp(me.id, secret, code);
    if (codes == null) {
      throw ApiError.badRequest({'code': ['Invalid code']});
    }
    return json({'success': true, 'recovery_codes': codes});
  }

  Response totpDeactivate(Request request) {
    final me = _me(request);
    if (!auth.mfaEnabled(me.id)) throw ApiError(404, 'TOTP not found');
    auth.disableTotp(me.id);
    return json(true);
  }

  /// Administratoren setzen die Zwei-Faktor-Anmeldung anderer zurück, etwa
  /// wenn das Telefon verloren ist.
  Response deactivateUserTotp(Request request) {
    access.require(_me(request), 'change', 'user');
    final row = _user(int.parse(request.params['id']!)) ?? (throw ApiError(404, 'Not found.'));
    if (row['totp_secret'] == null) throw ApiError(404, 'TOTP not found');
    auth.disableTotp(row['id'] as int);
    return json({'success': true});
  }

  static String _qrSvg(String data) {
    final qr = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    const quiet = 4;
    final size = qr.moduleCount + 2 * quiet;
    final path = StringBuffer();
    for (var y = 0; y < qr.moduleCount; y++) {
      for (var x = 0; x < qr.moduleCount; x++) {
        if (qr.isDark(y, x)) path.write('M${x + quiet} ${y + quiet}h1v1h-1z');
      }
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" '
        'shape-rendering="crispEdges"><rect width="$size" height="$size" fill="#fff"/>'
        '<path d="$path" fill="#000"/></svg>';
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/users/', listUsers);
    route('POST', '/api/users/', createUser);
    route('GET', '/api/users/<id|[0-9]+>/', getUser);
    route('PUT', '/api/users/<id|[0-9]+>/', updateUser);
    route('PATCH', '/api/users/<id|[0-9]+>/', updateUser);
    route('DELETE', '/api/users/<id|[0-9]+>/', deleteUser);
    route('GET', '/api/groups/', listGroups);
    route('POST', '/api/groups/', createGroup);
    route('GET', '/api/groups/<id|[0-9]+>/', getGroup);
    route('PUT', '/api/groups/<id|[0-9]+>/', updateGroup);
    route('PATCH', '/api/groups/<id|[0-9]+>/', updateGroup);
    route('DELETE', '/api/groups/<id|[0-9]+>/', deleteGroup);
    route('GET', '/api/profile/', profile);
    route('PATCH', '/api/profile/', updateProfile);
    route('POST', '/api/profile/generate_auth_token/', generateToken);
    route('GET', '/api/profile/totp/', totpSetup);
    route('POST', '/api/profile/totp/', totpActivate);
    route('DELETE', '/api/profile/totp/', totpDeactivate);
    route('POST', '/api/users/<id|[0-9]+>/deactivate_totp/', deactivateUserTotp);
  }
}
