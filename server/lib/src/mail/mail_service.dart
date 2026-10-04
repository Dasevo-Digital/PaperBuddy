import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../access.dart';
import '../api/http_utils.dart';
import '../auth.dart';
import '../db.dart';
import '../processing/consumer.dart';
import 'imap_client.dart';
import 'mime_message.dart';

final _log = Logger('mail');

/// Aktionen nach der Verarbeitung (`action` in Paperless-ngx).
abstract final class MailAction {
  static const delete = 1;
  static const move = 2;
  static const markRead = 3;
  static const flag = 4;
  static const tag = 5;
}

const _ruleDefaults = <String, Object?>{
  'name': '',
  'folder': 'INBOX',
  'filter_from': null,
  'filter_to': null,
  'filter_subject': null,
  'filter_body': null,
  'filter_attachment_filename_include': null,
  'filter_attachment_filename_exclude': null,
  'maximum_age': 30,
  'action': MailAction.markRead,
  'action_parameter': null,
  'assign_title_from': 1,
  'assign_tags': <int>[],
  'assign_correspondent_from': 1,
  'assign_correspondent': null,
  'assign_document_type': null,
  'assign_owner_from_rule': true,
  'attachment_type': 1,
  'consumption_scope': 1,
  'pdf_layout': 0,
};

/// Mailkonten, Regeln und regelmäßiger Abruf per IMAP.
class MailService {
  MailService({
    required this.db,
    required this.access,
    required this.consumer,
    required this.workDir,
    this.interval = const Duration(minutes: 10),
    this.connector = ImapClient.connect,
  });

  final Database db;
  final Access access;
  final Consumer consumer;
  final String workDir;
  final Duration interval;
  final Future<ImapClient> Function(String host, int port, ImapSecurity security) connector;
  Timer? _timer;
  bool _running = false;

  static const _masked = '**********';

  void start() {
    _timer = Timer.periodic(interval, (_) => processAll());
  }

  void stop() => _timer?.cancel();

  // ---------------------------------------------------------------------------
  // Abruf

  /// Alle Konten abrufen. Liefert die Zahl übernommener Dateien.
  Future<int> processAll() async {
    if (_running) return 0;
    _running = true;
    var total = 0;
    try {
      for (final a in db.select('SELECT id FROM mail_accounts')) {
        try {
          total += await processAccount(a['id'] as int);
        } catch (e) {
          _log.warning('Mailkonto ${a['id']}: $e');
        }
      }
    } finally {
      _running = false;
    }
    return total;
  }

  Future<int> processAccount(int accountId) async {
    final account = db.select('SELECT * FROM mail_accounts WHERE id = ?', [accountId]).firstOrNull;
    if (account == null) return 0;
    final rules = db.select(
      'SELECT * FROM mail_rules WHERE account_id = ? AND enabled = 1 ORDER BY sort_order, id',
      [accountId],
    );
    if (rules.isEmpty) return 0;
    final client = await _connect(account);
    var count = 0;
    try {
      for (final r in rules) {
        final rule = {..._ruleDefaults, ...jsonDecode(r['data'] as String) as Map<String, dynamic>};
        try {
          count += await _processRule(client, r['id'] as int, rule, r['owner'] as int?);
        } catch (e, st) {
          _log.warning('Mailregel „${rule['name']}“ fehlgeschlagen', e, st);
        }
      }
    } finally {
      await client.logout();
    }
    return count;
  }

  Future<ImapClient> _connect(Row account) async {
    final security = ImapSecurity.of(account['imap_security'] as int?);
    final port = account['imap_port'] as int? ?? (security == ImapSecurity.ssl ? 993 : 143);
    final client = await connector(account['imap_server'] as String, port, security);
    try {
      await client.login(account['username'] as String, account['password'] as String);
    } catch (_) {
      await client.close();
      rethrow;
    }
    return client;
  }

  static String _imapDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day}-${months[d.month - 1]}-${d.year}';
  }

  /// Suchkriterien wie in Paperless: bereits markierte Mails überspringen.
  String _criteria(Map<String, dynamic> rule) {
    final parts = <String>[];
    final age = asInt(rule['maximum_age']) ?? 0;
    if (age > 0) parts.add('SINCE ${_imapDate(DateTime.now().subtract(Duration(days: age)))}');
    switch (asInt(rule['action'])) {
      case MailAction.markRead:
        parts.add('UNSEEN');
      case MailAction.flag:
        parts.add('UNFLAGGED');
      case MailAction.tag:
        final keyword = '${rule['action_parameter'] ?? ''}'.trim();
        if (keyword.isNotEmpty) parts.add('UNKEYWORD $keyword');
    }
    String? text(String key) {
      final v = rule[key];
      return v == null || '$v'.trim().isEmpty ? null : '$v'.trim();
    }

    if (text('filter_from') case final v?) parts.add('FROM ${ImapClient.quote(v)}');
    if (text('filter_to') case final v?) parts.add('TO ${ImapClient.quote(v)}');
    if (text('filter_subject') case final v?) parts.add('SUBJECT ${ImapClient.quote(v)}');
    if (text('filter_body') case final v?) parts.add('BODY ${ImapClient.quote(v)}');
    return parts.isEmpty ? 'ALL' : parts.join(' ');
  }

  static bool _glob(String patterns, String value) => patterns
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .any((pattern) => RegExp(
            '^${pattern.split('').map((c) => switch (c) { '*' => '.*', '?' => '.', _ => RegExp.escape(c) }).join()}\$',
            caseSensitive: false,
          ).hasMatch(value));

  Future<int> _processRule(ImapClient client, int ruleId, Map<String, dynamic> rule, int? owner) async {
    final folder = '${rule['folder'] ?? 'INBOX'}';
    await client.select(folder);
    // Nicht-ASCII-Suchbegriffe brauchen CHARSET; dann lieber lokal filtern.
    final criteria = _criteria(rule);
    final ascii = criteria.codeUnits.every((c) => c < 128);
    final uids = await client.uidSearch(ascii ? criteria : 'ALL');
    var consumed = 0;
    for (final uid in uids) {
      final done = db.select(
        "SELECT 1 FROM mail_processed WHERE rule_id = ? AND folder = ? AND uid = ? AND status = 'SUCCESS'",
        [ruleId, folder, uid],
      ).isNotEmpty;
      if (done) continue;
      final raw = await client.fetchMessage(uid);
      if (raw == null) continue;
      final message = MailMessage.parse(raw);
      if (!ascii && !_matchesLocally(rule, message)) continue;
      try {
        final n = await _consumeMessage(message, ruleId, rule, owner);
        consumed += n;
        _record(ruleId, folder, uid, message, 'SUCCESS');
        await _afterProcessing(client, uid, rule);
      } catch (e) {
        _record(ruleId, folder, uid, message, 'FAILED', error: '$e');
        rethrow;
      }
    }
    return consumed;
  }

  bool _matchesLocally(Map<String, dynamic> rule, MailMessage m) {
    bool contains(String key, String value) {
      final f = rule[key];
      return f == null || '$f'.trim().isEmpty || value.toLowerCase().contains('$f'.trim().toLowerCase());
    }

    final (name, address) = m.from;
    return contains('filter_from', '$name $address') &&
        contains('filter_to', m.to) &&
        contains('filter_subject', m.subject) &&
        contains('filter_body', m.bodyText);
  }

  void _record(int ruleId, String folder, int uid, MailMessage m, String status, {String? error}) {
    db.execute(
      'INSERT INTO mail_processed (rule_id, folder, uid, message_id, subject, received, processed, status, error) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [ruleId, folder, uid, m.messageId, m.subject, m.date?.toIso8601String(), nowIso(), status, error],
    );
  }

  Future<void> _afterProcessing(ImapClient client, int uid, Map<String, dynamic> rule) async {
    final param = '${rule['action_parameter'] ?? ''}'.trim();
    switch (asInt(rule['action'])) {
      case MailAction.delete:
        await client.delete(uid);
      case MailAction.move:
        if (param.isNotEmpty) await client.move(uid, param);
      case MailAction.markRead:
        await client.addFlags(uid, r'\Seen');
      case MailAction.flag:
        await client.addFlags(uid, r'\Flagged');
      case MailAction.tag:
        if (param.isNotEmpty) await client.addFlags(uid, param);
    }
  }

  int? _correspondentFor(Map<String, dynamic> rule, MailMessage m) {
    final (name, address) = m.from;
    final String? wanted = switch (asInt(rule['assign_correspondent_from'])) {
      2 => address,
      3 => name.isEmpty ? address : name,
      4 => null,
      _ => null,
    };
    if (asInt(rule['assign_correspondent_from']) == 4) return asInt(rule['assign_correspondent']);
    if (wanted == null || wanted.isEmpty) return null;
    final existing = db.select('SELECT id FROM correspondents WHERE name = ? COLLATE NOCASE', [wanted]).firstOrNull;
    if (existing != null) return existing['id'] as int;
    db.execute('INSERT INTO correspondents (name, matching_algorithm) VALUES (?, 0)', [wanted]);
    return db.lastInsertRowId;
  }

  /// Anhänge (und je nach Regel die Mail selbst) an den Consumer geben.
  Future<int> _consumeMessage(MailMessage m, int ruleId, Map<String, dynamic> rule, int? owner) async {
    final scope = asInt(rule['consumption_scope']) ?? 1;
    final include = '${rule['filter_attachment_filename_include'] ?? ''}';
    final exclude = '${rule['filter_attachment_filename_exclude'] ?? ''}';
    final files = <(String, List<int>)>[];
    if (scope == 1 || scope == 3) {
      for (final part in m.attachments(includeInline: asInt(rule['attachment_type']) == 2)) {
        final name = p.basename(part.fileName!.replaceAll('\\', '/'));
        if (!supportedMimeTypes.containsKey(Consumer.detectMime(name, part.body))) continue;
        if (include.trim().isNotEmpty && !_glob(include, name)) continue;
        if (exclude.trim().isNotEmpty && _glob(exclude, name)) continue;
        files.add((name, part.body));
      }
    }
    if (scope == 2 || scope == 3) {
      // Die Mail selbst als Textdokument (ohne Umwandlung in PDF).
      final (name, address) = m.from;
      final text = 'Von: ${name.isEmpty ? address : '$name <$address>'}\n'
          'An: ${m.to}\nBetreff: ${m.subject}\n'
          'Datum: ${m.date?.toLocal().toIso8601String() ?? ''}\n\n${m.bodyText}';
      final safe = m.subject.replaceAll(RegExp(r'[^\w\s.-]', unicode: true), '_').trim();
      files.add(('${safe.isEmpty ? 'E-Mail' : safe}.txt', utf8.encode(text)));
    }
    if (files.isEmpty) return 0;

    final correspondent = _correspondentFor(rule, m);
    final dir = await Directory(p.join(workDir, 'mail')).create(recursive: true);
    for (final (name, bytes) in files) {
      final tmp = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}-$name'));
      await tmp.writeAsBytes(bytes);
      final title = switch (asInt(rule['assign_title_from'])) {
        1 => m.subject.trim().isEmpty ? null : m.subject.trim(),
        2 => p.basenameWithoutExtension(name),
        _ => null,
      };
      await consumer.submit(
        tmp,
        originalName: name,
        moveSource: true,
        source: ConsumeSource.mail,
        mailRule: ruleId,
        overrides: ConsumeOverrides(
          title: title,
          correspondent: correspondent,
          documentType: asInt(rule['assign_document_type']),
          tags: asIntList(rule['assign_tags']),
          owner: rule['assign_owner_from_rule'] == false ? null : owner,
        ),
      );
    }
    _log.info('${files.length} Datei(en) aus „${m.subject}“');
    return files.length;
  }

  // ---------------------------------------------------------------------------
  // API

  User _user(Request r) => r.context['user'] as User;

  Map<String, dynamic> _serializeAccount(Row a, User user) => {
        'id': a['id'],
        'name': a['name'],
        'imap_server': a['imap_server'],
        'imap_port': a['imap_port'],
        'imap_security': a['imap_security'],
        'username': a['username'],
        'password': _masked,
        'character_set': a['character_set'],
        'is_token': false,
        'account_type': 1,
        'expiration': null,
        'owner': a['owner'],
        'user_can_change': access.canChange(user, 'mailaccount', a['id'] as int, a['owner'] as int?),
      };

  Map<String, dynamic> _serializeRule(Row r, User user) => {
        ..._ruleDefaults,
        ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
        'id': r['id'],
        'account': r['account_id'],
        'order': r['sort_order'],
        'enabled': r['enabled'] == 1,
        'owner': r['owner'],
        'user_can_change': access.canChange(user, 'mailrule', r['id'] as int, r['owner'] as int?),
      };

  Response _listAccounts(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'mailaccount');
    final rows = db.select(
      'SELECT * FROM mail_accounts x WHERE ${access.visibleSql(user, 'mailaccount', 'x')} ORDER BY name COLLATE NOCASE',
    );
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) _serializeAccount(r, user)],
      allIds: [for (final r in rows) r['id'] as int],
      defaultPageSize: 100,
    );
  }

  Row _account(Request request) {
    final user = _user(request);
    return db.select(
          'SELECT * FROM mail_accounts x WHERE id = ? AND ${access.visibleSql(user, 'mailaccount', 'x')}',
          [int.parse(request.params['id']!)],
        ).firstOrNull ??
        (throw ApiError(404, 'Not found.'));
  }

  Map<String, Object?> _accountValues(Map<String, dynamic> body, {required bool partial}) {
    final v = <String, Object?>{};
    void put(String key, Object? Function(Object?) convert) {
      if (body.containsKey(key)) v[key] = convert(body[key]);
    }

    put('name', (x) => x?.toString().trim());
    put('imap_server', (x) => x?.toString().trim());
    put('imap_port', asInt);
    put('imap_security', (x) => asInt(x) ?? 2);
    put('username', (x) => x?.toString() ?? '');
    if (body.containsKey('password') && body['password'] != _masked) v['password'] = '${body['password'] ?? ''}';
    put('character_set', (x) => x?.toString() ?? 'UTF-8');
    put('owner', asInt);
    if (!partial) {
      for (final key in ['name', 'imap_server', 'username', 'password']) {
        if ('${v[key] ?? ''}'.isEmpty) throw ApiError.badRequest({key: ['This field is required.']});
      }
    }
    return v;
  }

  Future<Response> _createAccount(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'mailaccount');
    final values = _accountValues(await readBody(request), partial: false)..putIfAbsent('owner', () => user.id);
    final cols = values.keys.toList();
    try {
      db.execute(
        'INSERT INTO mail_accounts (${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})',
        [for (final c in cols) values[c]],
      );
    } on SqliteException catch (e) {
      if (e.extendedResultCode == 2067) throw ApiError.badRequest({'name': ['Mail account with this name already exists.']});
      rethrow;
    }
    final row = db.select('SELECT * FROM mail_accounts WHERE id = ?', [db.lastInsertRowId]).first;
    return json(_serializeAccount(row, user), status: 201);
  }

  Future<Response> _updateAccount(Request request) async {
    final user = _user(request);
    access.require(user, 'change', 'mailaccount');
    final row = _account(request);
    if (!access.canChange(user, 'mailaccount', row['id'] as int, row['owner'] as int?)) throw Access.forbidden();
    final values = _accountValues(await readBody(request), partial: true);
    if (values.isNotEmpty) {
      final cols = values.keys.toList();
      db.execute('UPDATE mail_accounts SET ${cols.map((c) => '$c = ?').join(', ')} WHERE id = ?',
          [for (final c in cols) values[c], row['id']]);
    }
    return json(_serializeAccount(db.select('SELECT * FROM mail_accounts WHERE id = ?', [row['id']]).first, user));
  }

  Response _deleteAccount(Request request) {
    final user = _user(request);
    access.require(user, 'delete', 'mailaccount');
    final row = _account(request);
    if (!access.canChange(user, 'mailaccount', row['id'] as int, row['owner'] as int?)) throw Access.forbidden();
    db.execute('DELETE FROM mail_accounts WHERE id = ?', [row['id']]);
    return Response(204);
  }

  /// `POST /api/mail_accounts/test/`: Anmeldung prüfen, ohne zu speichern.
  Future<Response> _testAccount(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'mailaccount');
    final body = await readBody(request);
    var password = '${body['password'] ?? ''}';
    if (password == _masked && body['id'] != null) {
      password = db.select('SELECT password FROM mail_accounts WHERE id = ?', [asInt(body['id'])]).firstOrNull?['password']
              as String? ??
          '';
    }
    final security = ImapSecurity.of(asInt(body['imap_security']));
    try {
      final client = await connector(
        '${body['imap_server']}',
        asInt(body['imap_port']) ?? (security == ImapSecurity.ssl ? 993 : 143),
        security,
      );
      try {
        await client.login('${body['username']}', password);
        final folders = await client.listMailboxes();
        return json({'success': true, 'folders': folders});
      } finally {
        await client.logout();
      }
    } catch (e) {
      throw ApiError(400, 'Unable to connect to server: $e');
    }
  }

  Future<Response> _processAccountNow(Request request) async {
    final user = _user(request);
    access.require(user, 'change', 'mailaccount');
    final row = _account(request);
    final n = await processAccount(row['id'] as int);
    return json({'result': 'OK', 'consumed': n});
  }

  Response _listRules(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'mailrule');
    final rows = db.select(
      'SELECT * FROM mail_rules x WHERE ${access.visibleSql(user, 'mailrule', 'x')} ORDER BY sort_order, id',
    );
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) _serializeRule(r, user)],
      allIds: [for (final r in rows) r['id'] as int],
      defaultPageSize: 100,
    );
  }

  Row _rule(Request request) {
    final user = _user(request);
    return db.select(
          'SELECT * FROM mail_rules x WHERE id = ? AND ${access.visibleSql(user, 'mailrule', 'x')}',
          [int.parse(request.params['id']!)],
        ).firstOrNull ??
        (throw ApiError(404, 'Not found.'));
  }

  Map<String, dynamic> _ruleData(Map<String, dynamic> body, Map<String, dynamic> previous) {
    final data = {...previous};
    for (final key in _ruleDefaults.keys) {
      if (body.containsKey(key)) data[key] = body[key];
    }
    if ('${data['name'] ?? ''}'.trim().isEmpty) throw ApiError.badRequest({'name': ['This field is required.']});
    final action = asInt(data['action']);
    if ((action == MailAction.move || action == MailAction.tag) && '${data['action_parameter'] ?? ''}'.trim().isEmpty) {
      throw ApiError.badRequest({'action_parameter': ['This action requires a parameter.']});
    }
    return data;
  }

  Future<Response> _createRule(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'mailrule');
    final body = await readBody(request);
    final account = asInt(body['account']);
    if (account == null || db.select('SELECT 1 FROM mail_accounts WHERE id = ?', [account]).isEmpty) {
      throw ApiError.badRequest({'account': ['Invalid mail account.']});
    }
    final data = _ruleData(body, const {});
    db.execute(
      'INSERT INTO mail_rules (account_id, sort_order, enabled, data, owner) VALUES (?, ?, ?, ?, ?)',
      [
        account,
        asInt(body['order']) ?? 0,
        body.containsKey('enabled') ? (asBool(body['enabled']) ? 1 : 0) : 1,
        jsonEncode(data),
        asInt(body['owner']) ?? user.id,
      ],
    );
    return json(_serializeRule(db.select('SELECT * FROM mail_rules WHERE id = ?', [db.lastInsertRowId]).first, user),
        status: 201);
  }

  Future<Response> _updateRule(Request request) async {
    final user = _user(request);
    access.require(user, 'change', 'mailrule');
    final row = _rule(request);
    if (!access.canChange(user, 'mailrule', row['id'] as int, row['owner'] as int?)) throw Access.forbidden();
    final body = await readBody(request);
    final data = _ruleData(body, jsonDecode(row['data'] as String) as Map<String, dynamic>);
    db.execute(
      'UPDATE mail_rules SET account_id = COALESCE(?, account_id), sort_order = COALESCE(?, sort_order), '
      'enabled = COALESCE(?, enabled), data = ? WHERE id = ?',
      [
        asInt(body['account']),
        asInt(body['order']),
        body.containsKey('enabled') ? (asBool(body['enabled']) ? 1 : 0) : null,
        jsonEncode(data),
        row['id'],
      ],
    );
    return json(_serializeRule(db.select('SELECT * FROM mail_rules WHERE id = ?', [row['id']]).first, user));
  }

  Response _deleteRule(Request request) {
    final user = _user(request);
    access.require(user, 'delete', 'mailrule');
    final row = _rule(request);
    if (!access.canChange(user, 'mailrule', row['id'] as int, row['owner'] as int?)) throw Access.forbidden();
    db.execute('DELETE FROM mail_rules WHERE id = ?', [row['id']]);
    return Response(204);
  }

  Response _processedMail(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'mailrule');
    final rule = asInt(request.url.queryParameters['rule']);
    final rows = db.select(
      'SELECT * FROM mail_processed${rule == null ? '' : ' WHERE rule_id = $rule'} ORDER BY processed DESC LIMIT 500',
    );
    return paginated(
      request,
      (limit, offset) => [
        for (final r in rows.skip(offset).take(limit))
          {
            'id': r['id'],
            'rule': r['rule_id'],
            'folder': r['folder'],
            'uid': r['uid'],
            'subject': r['subject'],
            'received': r['received'],
            'processed': r['processed'],
            'status': r['status'],
            'error': r['error'],
          },
      ],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/mail_accounts/', _listAccounts);
    route('POST', '/api/mail_accounts/', _createAccount);
    route('POST', '/api/mail_accounts/test/', _testAccount);
    route('GET', '/api/mail_accounts/<id|[0-9]+>/', (Request r) => json(_serializeAccount(_account(r), _user(r))));
    route('PUT', '/api/mail_accounts/<id|[0-9]+>/', _updateAccount);
    route('PATCH', '/api/mail_accounts/<id|[0-9]+>/', _updateAccount);
    route('DELETE', '/api/mail_accounts/<id|[0-9]+>/', _deleteAccount);
    route('POST', '/api/mail_accounts/<id|[0-9]+>/process/', _processAccountNow);
    route('GET', '/api/mail_rules/', _listRules);
    route('POST', '/api/mail_rules/', _createRule);
    route('GET', '/api/mail_rules/<id|[0-9]+>/', (Request r) => json(_serializeRule(_rule(r), _user(r))));
    route('PUT', '/api/mail_rules/<id|[0-9]+>/', _updateRule);
    route('PATCH', '/api/mail_rules/<id|[0-9]+>/', _updateRule);
    route('DELETE', '/api/mail_rules/<id|[0-9]+>/', _deleteRule);
    route('GET', '/api/processed_mail/', _processedMail);
  }
}
