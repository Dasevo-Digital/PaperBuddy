import 'dart:async';

import 'package:logging/logging.dart';
import 'package:mailer/mailer.dart' as mail;
import 'package:mailer/smtp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import 'access.dart';
import 'api/http_utils.dart';
import 'auth.dart';
import 'config.dart';
import 'db.dart';

final _log = Logger('reminders');

/// Fristen und Erinnerungen an Dokumenten (`/api/reminders/`), eine
/// PaperBuddy-Erweiterung: etwa „Kündigungsfrist 30.11.“ an einem Vertrag.
/// Jede Frist gehört dem Benutzer, der sie angelegt hat. Ist ein Mailserver
/// eingerichtet, kommt am Fälligkeitstag eine E-Mail.
class Reminders {
  Reminders({
    required this.db,
    required this.access,
    this.email,
    this.publicUrl,
    this.send,
  });

  final Database db;
  final Access access;
  final EmailSettings? email;
  final String? publicUrl;

  /// Für Tests austauschbar; sonst SMTP über [email].
  final Future<void> Function(mail.Message message)? send;

  Timer? _timer;

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  Map<String, dynamic> _serialize(Row r) => {
    'id': r['id'],
    'document': r['document_id'],
    'document_title': r['title'],
    'due': r['due'],
    'note': r['note'],
    'done': r['done'] == 1,
    'created': r['created'],
  };

  User _user(Request r) => r.context['user'] as User;

  /// Eigene Fristen an Dokumenten, die der Benutzer (noch) sehen darf.
  String _visible(User u) =>
      'r.owner = ${u.id} AND d.deleted_at IS NULL AND ${access.visibleSql(u, 'document', 'd')}';

  static const _select =
      'SELECT r.*, d.title FROM reminders r JOIN documents d ON d.id = r.document_id';

  Row _require(Request request) {
    final user = _user(request);
    final row = db.select(
      '$_select WHERE r.id = ? AND ${_visible(user)}',
      [int.parse(request.params['id']!)],
    ).firstOrNull;
    if (row == null) throw ApiError(404, 'Not found.');
    return row;
  }

  Response list(Request request) {
    final user = _user(request);
    access.require(user, 'view', 'document');
    final q = request.url.queryParameters;
    final where = <String>[_visible(user)];
    final args = <Object?>[];
    final doc = asInt(q['document']);
    if (doc != null) {
      where.add('r.document_id = ?');
      args.add(doc);
    }
    if (q.containsKey('done')) where.add('r.done = ${asBool(q['done']) ? 1 : 0}');
    final dueBefore = q['due__lte'];
    if (dueBefore != null && DateTime.tryParse(dueBefore) != null) {
      where.add('r.due <= ?');
      args.add(_day(DateTime.parse(dueBefore)));
    }
    final rows = db.select(
      '$_select WHERE ${where.join(' AND ')} ORDER BY r.done, r.due, r.id',
      args,
    );
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) _serialize(r)],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  Response get(Request request) => json(_serialize(_require(request)));

  Future<Response> create(Request request) async {
    final user = _user(request);
    access.require(user, 'view', 'document');
    final body = await readBody(request);
    final docId = asInt(body['document']);
    final due = DateTime.tryParse('${body['due'] ?? ''}');
    if (docId == null || due == null) {
      throw ApiError.badRequest({
        if (docId == null) 'document': ['This field is required.'],
        if (due == null) 'due': ['Enter a valid date.'],
      });
    }
    final visible = db.select(
      'SELECT 1 FROM documents d WHERE d.id = ? AND d.deleted_at IS NULL AND ${access.visibleSql(user, 'document', 'd')}',
      [docId],
    );
    if (visible.isEmpty) throw ApiError(404, 'Document not found.');
    db.execute(
      'INSERT INTO reminders (document_id, owner, due, note, created) VALUES (?, ?, ?, ?, ?)',
      [docId, user.id, _day(due), '${body['note'] ?? ''}'.trim(), nowIso()],
    );
    final row = db.select('$_select WHERE r.id = ?', [db.lastInsertRowId]).first;
    return json(_serialize(row), status: 201);
  }

  Future<Response> update(Request request) async {
    final row = _require(request);
    final body = await readBody(request);
    final id = row['id'] as int;
    if (body.containsKey('due')) {
      final due = DateTime.tryParse('${body['due']}');
      if (due == null) throw ApiError.badRequest({'due': ['Enter a valid date.']});
      // Neues Datum: erneut erinnern.
      db.execute('UPDATE reminders SET due = ?, notified = 0 WHERE id = ?', [_day(due), id]);
    }
    if (body.containsKey('note')) {
      db.execute('UPDATE reminders SET note = ? WHERE id = ?', ['${body['note'] ?? ''}'.trim(), id]);
    }
    if (body.containsKey('done')) {
      db.execute('UPDATE reminders SET done = ? WHERE id = ?', [asBool(body['done']) ? 1 : 0, id]);
    }
    return json(_serialize(db.select('$_select WHERE r.id = ?', [id]).first));
  }

  Response delete(Request request) {
    db.execute('DELETE FROM reminders WHERE id = ?', [_require(request)['id']]);
    return Response(204);
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/reminders/', list);
    route('POST', '/api/reminders/', create);
    route('GET', '/api/reminders/<id|[0-9]+>/', get);
    route('PATCH', '/api/reminders/<id|[0-9]+>/', update);
    route('PUT', '/api/reminders/<id|[0-9]+>/', update);
    route('DELETE', '/api/reminders/<id|[0-9]+>/', delete);
  }

  // E-Mail am Fälligkeitstag ---------------------------------------------------

  void start() {
    if (email == null && send == null) return;
    notifyDue().ignore();
    _timer = Timer.periodic(const Duration(hours: 1), (_) => notifyDue().ignore());
  }

  void stop() => _timer?.cancel();

  /// Schickt jedem Benutzer eine E-Mail mit seinen heute fälligen oder
  /// überfälligen, noch nicht gemeldeten Fristen. Liefert die Anzahl Mails.
  Future<int> notifyDue({DateTime? today}) async {
    final day = _day(today ?? DateTime.now());
    final rows = db.select(
      'SELECT r.*, d.title, u.email, u.username FROM reminders r '
      'JOIN documents d ON d.id = r.document_id JOIN users u ON u.id = r.owner '
      "WHERE r.done = 0 AND r.notified = 0 AND r.due <= ? AND d.deleted_at IS NULL AND u.email != ''",
      [day],
    );
    final byUser = <String, List<Row>>{};
    for (final r in rows) {
      byUser.putIfAbsent(r['email'] as String, () => []).add(r);
    }
    var sent = 0;
    for (final MapEntry(key: to, value: list) in byUser.entries) {
      final lines = [
        for (final r in list)
          '• ${r['due']}: ${r['title']}'
              '${(r['note'] as String).isEmpty ? '' : ' – ${r['note']}'}'
              '${publicUrl == null ? '' : '\n  ${publicUrl!.replaceAll(RegExp(r'/+$'), '')}/documents/${r['document_id']}/details'}',
      ];
      final message = mail.Message()
        ..from = mail.Address(email?.from ?? 'paperbuddy@localhost', 'PaperBuddy')
        ..recipients.add(to)
        ..subject = list.length == 1
            ? 'Frist fällig: ${list.single['title']}'
            : '${list.length} Fristen fällig'
        ..text = 'Hallo ${list.first['username']},\n\n'
            'folgende Fristen sind fällig:\n\n${lines.join('\n')}\n\n'
            'Erledigte Fristen lassen sich in der App abhaken.\n';
      try {
        await (send ?? _smtp)(message);
        for (final r in list) {
          db.execute('UPDATE reminders SET notified = 1 WHERE id = ?', [r['id']]);
        }
        sent++;
      } catch (e) {
        _log.warning('Erinnerung an $to nicht gesendet: $e');
      }
    }
    return sent;
  }

  Future<void> _smtp(mail.Message message) async {
    final s = email!;
    await mail.send(
      message,
      SmtpServer(
        s.host,
        port: s.port,
        username: s.username,
        password: s.password,
        ssl: s.ssl,
        allowInsecure: !s.ssl && !s.startTls,
      ),
    );
  }
}
