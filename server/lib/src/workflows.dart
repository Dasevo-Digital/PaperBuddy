import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:mailer/mailer.dart' as mail;
import 'package:mailer/smtp_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import 'access.dart';
import 'api/custom_fields.dart';
import 'api/http_utils.dart';
import 'auth.dart';
import 'config.dart';
import 'db.dart';
import 'processing/consumer.dart';
import 'processing/matching.dart';
import 'storage.dart';

final _log = Logger('workflows');

/// Auslöser wie in Paperless-ngx.
abstract final class TriggerType {
  static const consumption = 1;
  static const documentAdded = 2;
  static const documentUpdated = 3;
  static const scheduled = 4;
}

abstract final class ActionType {
  static const assignment = 1;
  static const removal = 2;
  static const email = 3;
  static const webhook = 4;
}

const _triggerDefaults = <String, Object?>{
  'type': TriggerType.consumption,
  'sources': [1, 2, 3],
  'filter_path': null,
  'filter_filename': null,
  'filter_mailrule': null,
  'matching_algorithm': 0,
  'match': '',
  'is_insensitive': true,
  'filter_has_tags': <int>[],
  'filter_has_correspondent': null,
  'filter_has_document_type': null,
  'schedule_offset_days': 0,
  'schedule_is_recurring': false,
  'schedule_recurring_interval_days': 1,
  'schedule_date_field': 'added',
  'schedule_date_custom_field': null,
};

const _actionDefaults = <String, Object?>{
  'type': ActionType.assignment,
  'assign_title': null,
  'assign_tags': <int>[],
  'assign_correspondent': null,
  'assign_document_type': null,
  'assign_storage_path': null,
  'assign_owner': null,
  'assign_view_users': <int>[],
  'assign_view_groups': <int>[],
  'assign_change_users': <int>[],
  'assign_change_groups': <int>[],
  'assign_custom_fields': <int>[],
  'assign_custom_fields_values': <String, Object?>{},
  'remove_all_tags': false,
  'remove_tags': <int>[],
  'remove_all_correspondents': false,
  'remove_correspondents': <int>[],
  'remove_all_document_types': false,
  'remove_document_types': <int>[],
  'remove_all_storage_paths': false,
  'remove_storage_paths': <int>[],
  'remove_custom_fields': <int>[],
  'remove_all_custom_fields': false,
  'remove_all_owners': false,
  'remove_owners': <int>[],
  'remove_all_permissions': false,
  'remove_view_users': <int>[],
  'remove_view_groups': <int>[],
  'remove_change_users': <int>[],
  'remove_change_groups': <int>[],
  'email': null,
  'webhook': null,
};

/// Workflows: API und Ausführung.
class WorkflowEngine implements ConsumeHooks {
  WorkflowEngine({
    required this.db,
    required this.access,
    required this.store,
    required this.customFields,
    this.email,
    this.publicUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Database db;
  final Access access;
  final BlobStore store;
  final CustomFieldsResource customFields;
  final EmailSettings? email;
  final String? publicUrl;
  final http.Client _http;
  Timer? _scheduler;

  /// Verhindert, dass eine Aktion „Dokument geändert“ erneut auslöst.
  final _running = <int>{};

  // ---------------------------------------------------------------------------
  // Laden

  List<_Workflow> _workflows({int? triggerType}) {
    final result = <_Workflow>[];
    for (final w in db.select('SELECT * FROM workflows WHERE enabled = 1 ORDER BY sort_order, id')) {
      final id = w['id'] as int;
      final triggers = [
        for (final t in db.select('SELECT id, data FROM workflow_triggers WHERE workflow_id = ? ORDER BY id', [id]))
          {..._triggerDefaults, ...jsonDecode(t['data'] as String) as Map<String, dynamic>, 'id': t['id']},
      ].where((t) => triggerType == null || t['type'] == triggerType).toList();
      if (triggers.isEmpty) continue;
      final actions = [
        for (final a in db.select(
            'SELECT id, data FROM workflow_actions WHERE workflow_id = ? ORDER BY sort_order, id', [id]))
          {..._actionDefaults, ...jsonDecode(a['data'] as String) as Map<String, dynamic>, 'id': a['id']},
      ];
      result.add(_Workflow(id, w['name'] as String, triggers, actions));
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Filter

  static bool _glob(String pattern, String value) {
    final re = RegExp(
      '^${pattern.split('').map((c) => switch (c) { '*' => '.*', '?' => '.', _ => RegExp.escape(c) }).join()}\$',
      caseSensitive: false,
    );
    return re.hasMatch(value);
  }

  bool _matchesConsumption(Map<String, dynamic> t, String fileName, String? path, ConsumeSource source, int? mailRule) {
    if (!asIntList(t['sources']).contains(source.value)) return false;
    final fname = t['filter_filename'] as String?;
    if (fname != null && fname.isNotEmpty && !_glob(fname, fileName)) return false;
    final fpath = t['filter_path'] as String?;
    if (fpath != null && fpath.isNotEmpty && (path == null || !_glob(fpath, path))) return false;
    final rule = asInt(t['filter_mailrule']);
    if (rule != null && rule != mailRule) return false;
    return true;
  }

  bool _matchesDocument(Map<String, dynamic> t, Row doc, {ConsumeSource? source}) {
    if (source != null && t['type'] == TriggerType.documentAdded && !asIntList(t['sources']).contains(source.value)) {
      return false;
    }
    final fname = t['filter_filename'] as String?;
    if (fname != null && fname.isNotEmpty && !_glob(fname, doc['original_filename'] as String)) return false;
    final tags = asIntList(t['filter_has_tags']);
    if (tags.isNotEmpty) {
      final has = {
        for (final r in db.select('SELECT tag_id FROM document_tags WHERE document_id = ?', [doc['id']]))
          r['tag_id'] as int,
      };
      if (!tags.every(has.contains)) return false;
    }
    final corr = asInt(t['filter_has_correspondent']);
    if (corr != null && doc['correspondent_id'] != corr) return false;
    final type = asInt(t['filter_has_document_type']);
    if (type != null && doc['document_type_id'] != type) return false;
    final algorithm = asInt(t['matching_algorithm']) ?? 0;
    if (algorithm != 0 &&
        !matches('${doc['title']}\n${doc['content']}', '${t['match'] ?? ''}', algorithm, t['is_insensitive'] != false)) {
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // ConsumeHooks

  @override
  void consumptionStarted({
    required String fileName,
    required String? path,
    required ConsumeSource source,
    required ConsumeOverrides overrides,
    int? mailRule,
  }) {
    for (final w in _workflows(triggerType: TriggerType.consumption)) {
      if (!w.triggers.any((t) => _matchesConsumption(t, fileName, path, source, mailRule))) continue;
      _log.info('Workflow „${w.name}“ bei Verarbeitung von $fileName');
      for (final a in w.actions) {
        _applyToOverrides(a, overrides);
      }
    }
  }

  void _applyToOverrides(Map<String, dynamic> a, ConsumeOverrides o) {
    if (a['type'] == ActionType.assignment) {
      final title = a['assign_title'] as String?;
      if (title != null && title.isNotEmpty) o.titleTemplate = title;
      o.tags.addAll(asIntList(a['assign_tags']));
      o.correspondent = asInt(a['assign_correspondent']) ?? o.correspondent;
      o.documentType = asInt(a['assign_document_type']) ?? o.documentType;
      o.storagePath = asInt(a['assign_storage_path']) ?? o.storagePath;
      o.owner = asInt(a['assign_owner']) ?? o.owner;
      o.viewUsers.addAll(asIntList(a['assign_view_users']));
      o.viewGroups.addAll(asIntList(a['assign_view_groups']));
      o.changeUsers.addAll(asIntList(a['assign_change_users']));
      o.changeGroups.addAll(asIntList(a['assign_change_groups']));
      final values = (a['assign_custom_fields_values'] as Map?) ?? {};
      for (final f in asIntList(a['assign_custom_fields'])) {
        o.customFieldValues[f] = values['$f'];
      }
    } else if (a['type'] == ActionType.removal) {
      if (a['remove_all_tags'] == true) {
        o.tags.clear();
      } else {
        o.tags.removeWhere(asIntList(a['remove_tags']).contains);
      }
      if (a['remove_all_correspondents'] == true || asIntList(a['remove_correspondents']).contains(o.correspondent)) {
        o.correspondent = null;
      }
      if (a['remove_all_document_types'] == true || asIntList(a['remove_document_types']).contains(o.documentType)) {
        o.documentType = null;
      }
      if (a['remove_all_storage_paths'] == true || asIntList(a['remove_storage_paths']).contains(o.storagePath)) {
        o.storagePath = null;
      }
      if (a['remove_all_custom_fields'] == true) {
        o.customFieldValues.clear();
      } else {
        asIntList(a['remove_custom_fields']).forEach(o.customFieldValues.remove);
      }
      if (a['remove_all_owners'] == true || asIntList(a['remove_owners']).contains(o.owner)) o.owner = null;
      if (a['remove_all_permissions'] == true) {
        o.viewUsers.clear();
        o.viewGroups.clear();
        o.changeUsers.clear();
        o.changeGroups.clear();
      } else {
        o.viewUsers.removeAll(asIntList(a['remove_view_users']));
        o.viewGroups.removeAll(asIntList(a['remove_view_groups']));
        o.changeUsers.removeAll(asIntList(a['remove_change_users']));
        o.changeGroups.removeAll(asIntList(a['remove_change_groups']));
      }
    }
    // E-Mail und Webhook laufen erst, wenn das Dokument existiert.
  }

  @override
  Future<void> documentAdded(int documentId,
      {required ConsumeSource source, required String fileName, int? mailRule}) async {
    await _runForDocument(documentId, TriggerType.documentAdded, source: source);
  }

  /// Nach Änderungen über die API.
  Future<void> documentUpdated(int documentId) => _runForDocument(documentId, TriggerType.documentUpdated);

  Future<void> _runForDocument(int documentId, int triggerType, {ConsumeSource? source}) async {
    if (_running.contains(documentId)) return;
    _running.add(documentId);
    try {
      for (final w in _workflows(triggerType: triggerType)) {
        final doc = _doc(documentId);
        if (doc == null) return;
        if (!w.triggers.any((t) => _matchesDocument(t, doc, source: source))) continue;
        _log.info('Workflow „${w.name}“ für Dokument #$documentId');
        await _runActions(w, documentId, triggerType);
      }
    } finally {
      _running.remove(documentId);
    }
  }

  Row? _doc(int id) => db.select('SELECT * FROM documents WHERE id = ? AND deleted_at IS NULL', [id]).firstOrNull;

  Future<void> _runActions(_Workflow w, int documentId, int triggerType) async {
    for (final a in w.actions) {
      try {
        switch (a['type']) {
          case ActionType.assignment:
            _assign(a, documentId);
          case ActionType.removal:
            _remove(a, documentId);
          case ActionType.email:
            await _sendEmail(a, documentId);
          case ActionType.webhook:
            await _callWebhook(a, documentId);
        }
      } catch (e, st) {
        _log.warning('Aktion ${a['id']} von Workflow „${w.name}“ fehlgeschlagen', e, st);
      }
    }
    db.execute(
      'INSERT INTO workflow_runs (workflow_id, document_id, trigger_type, run_at) VALUES (?, ?, ?, ?)',
      [w.id, documentId, triggerType, nowIso()],
    );
  }

  void _assign(Map<String, dynamic> a, int id) {
    final title = a['assign_title'] as String?;
    if (title != null && title.isNotEmpty) {
      final rendered = renderTitle(title, id).trim();
      if (rendered.isNotEmpty) db.execute('UPDATE documents SET title = ? WHERE id = ?', [rendered, id]);
    }
    for (final t in asIntList(a['assign_tags'])) {
      db.execute('INSERT OR IGNORE INTO document_tags (document_id, tag_id) SELECT ?, id FROM tags WHERE id = ?', [id, t]);
    }
    for (final (column, key) in [
      ('correspondent_id', 'assign_correspondent'),
      ('document_type_id', 'assign_document_type'),
      ('storage_path_id', 'assign_storage_path'),
      ('owner', 'assign_owner'),
    ]) {
      final v = asInt(a[key]);
      if (v != null) db.execute('UPDATE documents SET $column = ? WHERE id = ?', [v, id]);
    }
    final perms = {
      'view': {'users': asIntList(a['assign_view_users']), 'groups': asIntList(a['assign_view_groups'])},
      'change': {'users': asIntList(a['assign_change_users']), 'groups': asIntList(a['assign_change_groups'])},
    };
    access.setPermissions('document', id, perms, merge: true);
    final values = (a['assign_custom_fields_values'] as Map?) ?? {};
    final fields = asIntList(a['assign_custom_fields']);
    if (fields.isNotEmpty) {
      customFields.addValues(id, {for (final f in fields) '$f': values['$f']});
    }
    db.execute('UPDATE documents SET modified = ? WHERE id = ?', [nowIso(), id]);
  }

  void _remove(Map<String, dynamic> a, int id) {
    if (a['remove_all_tags'] == true) {
      db.execute('DELETE FROM document_tags WHERE document_id = ?', [id]);
    } else if (asIntList(a['remove_tags']).isNotEmpty) {
      db.execute('DELETE FROM document_tags WHERE document_id = ? AND tag_id IN (${asIntList(a['remove_tags']).join(',')})', [id]);
    }
    for (final (column, all, some) in [
      ('correspondent_id', 'remove_all_correspondents', 'remove_correspondents'),
      ('document_type_id', 'remove_all_document_types', 'remove_document_types'),
      ('storage_path_id', 'remove_all_storage_paths', 'remove_storage_paths'),
      ('owner', 'remove_all_owners', 'remove_owners'),
    ]) {
      if (a[all] == true) {
        db.execute('UPDATE documents SET $column = NULL WHERE id = ?', [id]);
      } else if (asIntList(a[some]).isNotEmpty) {
        db.execute('UPDATE documents SET $column = NULL WHERE id = ? AND $column IN (${asIntList(a[some]).join(',')})', [id]);
      }
    }
    if (a['remove_all_custom_fields'] == true) {
      db.execute('DELETE FROM document_custom_fields WHERE document_id = ?', [id]);
    } else {
      customFields.removeFields(id, asIntList(a['remove_custom_fields']));
    }
    if (a['remove_all_permissions'] == true) {
      access.forgetObject('document', id);
    } else {
      for (final (perm, column, key) in [
        ('view', 'user_id', 'remove_view_users'),
        ('view', 'group_id', 'remove_view_groups'),
        ('change', 'user_id', 'remove_change_users'),
        ('change', 'group_id', 'remove_change_groups'),
      ]) {
        final ids = asIntList(a[key]);
        if (ids.isEmpty) continue;
        db.execute(
          "DELETE FROM object_permissions WHERE object_type = 'document' AND object_id = ? "
          'AND permission = ? AND $column IN (${ids.join(',')})',
          [id, perm],
        );
      }
    }
    db.execute('UPDATE documents SET modified = ? WHERE id = ?', [nowIso(), id]);
  }

  // ---------------------------------------------------------------------------
  // Platzhalter

  Map<String, String> placeholders(int id) {
    final d = db.select(
      'SELECT d.*, c.name AS correspondent, t.name AS document_type, u.username AS owner_username '
      'FROM documents d LEFT JOIN correspondents c ON c.id = d.correspondent_id '
      'LEFT JOIN document_types t ON t.id = d.document_type_id LEFT JOIN users u ON u.id = d.owner '
      'WHERE d.id = ?',
      [id],
    ).firstOrNull;
    if (d == null) return {};
    final added = DateTime.parse(d['added'] as String).toLocal();
    final created = DateTime.parse(d['created'] as String);
    String two(int v) => v.toString().padLeft(2, '0');
    final months = DateFormat('MMMM', 'en');
    final monthsShort = DateFormat('MMM', 'en');
    Map<String, String> dates(String prefix, DateTime t) => {
          prefix: dateOnly(t),
          '${prefix}_year': '${t.year}',
          '${prefix}_year_short': two(t.year % 100),
          '${prefix}_month': two(t.month),
          '${prefix}_month_name': months.format(t),
          '${prefix}_month_name_short': monthsShort.format(t),
          '${prefix}_day': two(t.day),
        };
    final original = d['original_filename'] as String;
    return {
      'correspondent': (d['correspondent'] as String?) ?? '',
      'document_type': (d['document_type'] as String?) ?? '',
      'owner_username': (d['owner_username'] as String?) ?? '',
      'original_filename': p.basenameWithoutExtension(original),
      'filename': original,
      'doc_title': d['title'] as String,
      'doc_id': '$id',
      'doc_url': publicUrl == null ? '' : '${publicUrl!.replaceAll(RegExp(r'/+$'), '')}/documents/$id/details',
      ...dates('added', added),
      'added_time': '${two(added.hour)}:${two(added.minute)}',
      ...dates('created', created),
    };
  }

  @override
  String renderTitle(String template, int documentId) => render(template, documentId);

  String render(String template, int documentId) {
    final values = placeholders(documentId);
    return template.replaceAllMapped(RegExp(r'\{\{?\s*([a-z_]+)\s*\}?\}'), (m) => values[m.group(1)] ?? m.group(0)!);
  }

  // ---------------------------------------------------------------------------
  // E-Mail und Webhook

  Future<void> _sendEmail(Map<String, dynamic> a, int id) async {
    final cfg = (a['email'] as Map?)?.cast<String, dynamic>();
    if (cfg == null) return;
    final settings = email;
    if (settings == null) {
      _log.warning('E-Mail-Aktion übersprungen: EMAIL_HOST ist nicht gesetzt.');
      return;
    }
    final to = '${cfg['to'] ?? ''}'.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (to.isEmpty) return;
    final message = mail.Message()
      ..from = mail.Address(settings.from, 'PaperBuddy')
      ..recipients.addAll(to)
      ..subject = render('${cfg['subject'] ?? ''}', id)
      ..text = render('${cfg['body'] ?? ''}', id);
    if (cfg['include_document'] == true) {
      final file = await _documentFile(id);
      if (file != null) message.attachments.add(mail.FileAttachment(file.$1, fileName: file.$2));
    }
    final server = SmtpServer(
      settings.host,
      port: settings.port,
      username: settings.username,
      password: settings.password,
      ssl: settings.ssl,
      allowInsecure: !settings.ssl && !settings.startTls,
    );
    await mail.send(message, server);
  }

  Future<(File, String)?> _documentFile(int id) async {
    final d = db.select('SELECT archive_path, original_path, original_filename FROM documents WHERE id = ?', [id]).first;
    final archive = d['archive_path'] as String?;
    if (archive != null) {
      final f = await store.get(archive);
      if (f != null) return (f, '${p.basenameWithoutExtension(d['original_filename'] as String)}.pdf');
    }
    final f = await store.get(d['original_path'] as String);
    return f == null ? null : (f, d['original_filename'] as String);
  }

  Future<void> _callWebhook(Map<String, dynamic> a, int id) async {
    final cfg = (a['webhook'] as Map?)?.cast<String, dynamic>();
    if (cfg == null) return;
    final url = Uri.parse(render('${cfg['url']}', id));
    final headers = <String, String>{
      for (final e in ((cfg['headers'] as Map?) ?? {}).entries) '${e.key}': render('${e.value}', id),
    };
    final http.BaseRequest request;
    if (cfg['include_document'] == true) {
      final r = http.MultipartRequest('POST', url);
      final file = await _documentFile(id);
      if (file != null) r.files.add(await http.MultipartFile.fromPath('file', file.$1.path, filename: file.$2));
      if (cfg['use_params'] == true) {
        r.fields.addAll({for (final e in ((cfg['params'] as Map?) ?? {}).entries) '${e.key}': render('${e.value}', id)});
      }
      request = r;
    } else if (cfg['use_params'] == true) {
      final params = {for (final e in ((cfg['params'] as Map?) ?? {}).entries) '${e.key}': render('${e.value}', id)};
      final r = http.Request('POST', url);
      if (cfg['as_json'] == true) {
        r.headers['content-type'] = 'application/json';
        r.body = jsonEncode(params);
      } else {
        r.bodyFields = params;
      }
      request = r;
    } else {
      final r = http.Request('POST', url)..body = render('${cfg['body'] ?? ''}', id);
      request = r;
    }
    request.headers.addAll(headers);
    final response = await _http.send(request).timeout(const Duration(seconds: 30));
    await response.stream.drain<void>();
    if (response.statusCode >= 400) {
      _log.warning('Webhook $url antwortete mit ${response.statusCode}');
    }
  }

  // ---------------------------------------------------------------------------
  // Zeitgesteuerte Workflows

  void startScheduler() {
    _scheduler = Timer.periodic(const Duration(hours: 1), (_) => runScheduled());
    runScheduled();
  }

  void stop() {
    _scheduler?.cancel();
    _http.close();
  }

  /// Führt fällige zeitgesteuerte Workflows aus.
  Future<int> runScheduled({DateTime? now}) async {
    now ??= DateTime.now();
    var runs = 0;
    for (final w in _workflows(triggerType: TriggerType.scheduled)) {
      for (final t in w.triggers) {
        final offset = asInt(t['schedule_offset_days']) ?? 0;
        final field = '${t['schedule_date_field']}';
        final recurring = t['schedule_is_recurring'] == true;
        final interval = asInt(t['schedule_recurring_interval_days']) ?? 1;
        for (final d in db.select('SELECT * FROM documents WHERE deleted_at IS NULL')) {
          final id = d['id'] as int;
          final base = _scheduleDate(d, field, asInt(t['schedule_date_custom_field']));
          if (base == null || now.isBefore(base.add(Duration(days: offset)))) continue;
          if (!_matchesDocument(t, d)) continue;
          final last = db.select(
            'SELECT MAX(run_at) AS r FROM workflow_runs WHERE workflow_id = ? AND document_id = ? AND trigger_type = ?',
            [w.id, id, TriggerType.scheduled],
          ).first['r'] as String?;
          if (last != null) {
            if (!recurring) continue;
            if (now.isBefore(DateTime.parse(last).add(Duration(days: interval)))) continue;
          }
          await _runActions(w, id, TriggerType.scheduled);
          runs++;
        }
      }
    }
    return runs;
  }

  DateTime? _scheduleDate(Row d, String field, int? customField) {
    if (field == 'custom_field' && customField != null) {
      final v = db.select('SELECT value FROM document_custom_fields WHERE document_id = ? AND field_id = ?',
          [d['id'], customField]).firstOrNull?['value'] as String?;
      return v == null ? null : DateTime.tryParse(jsonDecode(v).toString());
    }
    final raw = d[switch (field) { 'created' => 'created', 'modified' => 'modified', _ => 'added' }] as String?;
    return raw == null ? null : DateTime.tryParse(raw);
  }

  // ---------------------------------------------------------------------------
  // API

  Map<String, dynamic> _serializeWorkflow(Row w) {
    final id = w['id'] as int;
    return {
      'id': id,
      'name': w['name'],
      'order': w['sort_order'],
      'enabled': w['enabled'] == 1,
      'triggers': [
        for (final t in db.select('SELECT id, data FROM workflow_triggers WHERE workflow_id = ? ORDER BY id', [id]))
          {..._triggerDefaults, ...jsonDecode(t['data'] as String) as Map<String, dynamic>, 'id': t['id']},
      ],
      'actions': [
        for (final a in db.select('SELECT id, data FROM workflow_actions WHERE workflow_id = ? ORDER BY sort_order, id', [id]))
          {..._actionDefaults, ...jsonDecode(a['data'] as String) as Map<String, dynamic>, 'id': a['id']},
      ],
    };
  }

  User _user(Request r) => r.context['user'] as User;

  Response _list(Request request) {
    access.require(_user(request), 'view', 'workflow');
    final rows = db.select('SELECT * FROM workflows ORDER BY sort_order, id');
    return paginated(
      request,
      (limit, offset) => [for (final r in rows.skip(offset).take(limit)) _serializeWorkflow(r)],
      allIds: [for (final r in rows) r['id'] as int],
      defaultPageSize: 100,
    );
  }

  Row _require(Request request) =>
      db.select('SELECT * FROM workflows WHERE id = ?', [int.parse(request.params['id']!)]).firstOrNull ??
      (throw ApiError(404, 'Not found.'));

  Response _get(Request request) {
    access.require(_user(request), 'view', 'workflow');
    return json(_serializeWorkflow(_require(request)));
  }

  Map<String, dynamic> _clean(Map<String, dynamic> input, Map<String, Object?> defaults) => {
        for (final key in defaults.keys)
          if (input.containsKey(key)) key: input[key],
      };

  void _validateTrigger(Map<String, dynamic> t) {
    final type = asInt(t['type']);
    if (type == null || type < 1 || type > 4) throw ApiError.badRequest({'triggers': ['Invalid trigger type.']});
    if (type == TriggerType.consumption) {
      final f = t['filter_filename'], p = t['filter_path'], m = t['filter_mailrule'];
      if ((f == null || '$f'.isEmpty) && (p == null || '$p'.isEmpty) && m == null) {
        throw ApiError.badRequest({
          'triggers': ['File name, path or mail rule filter are required'],
        });
      }
    }
  }

  void _validateAction(Map<String, dynamic> a) {
    final type = asInt(a['type']);
    if (type == null || type < 1 || type > 4) throw ApiError.badRequest({'actions': ['Invalid action type.']});
    if (type == ActionType.email && (a['email'] is! Map || '${(a['email'] as Map)['to'] ?? ''}'.isEmpty)) {
      throw ApiError.badRequest({'actions': ['Email action requires a recipient.']});
    }
    if (type == ActionType.webhook && (a['webhook'] is! Map || Uri.tryParse('${(a['webhook'] as Map)['url']}')?.hasScheme != true)) {
      throw ApiError.badRequest({'actions': ['Webhook action requires a valid URL.']});
    }
  }

  /// Verschachtelte Auslöser/Aktionen: mit `id` aktualisieren, ohne `id`
  /// anlegen, fehlende entfernen.
  void _syncChildren(int workflowId, String table, Object? items, Map<String, Object?> defaults,
      void Function(Map<String, dynamic>) validate) {
    if (items is! List) return;
    final keep = <int>[];
    var order = 0;
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      final data = _clean(item, defaults);
      validate({...defaults, ...data});
      final id = asInt(item['id']);
      final existing = id == null
          ? null
          : db.select('SELECT id FROM $table WHERE id = ? AND workflow_id = ?', [id, workflowId]).firstOrNull;
      final hasOrder = table == 'workflow_actions';
      if (existing != null) {
        db.execute(
          'UPDATE $table SET data = ?${hasOrder ? ', sort_order = $order' : ''} WHERE id = ?',
          [jsonEncode(data), id],
        );
        keep.add(id!);
      } else {
        db.execute(
          'INSERT INTO $table (workflow_id, data${hasOrder ? ', sort_order' : ''}) VALUES (?, ?${hasOrder ? ', $order' : ''})',
          [workflowId, jsonEncode(data)],
        );
        keep.add(db.lastInsertRowId);
      }
      order++;
    }
    db.execute(
      'DELETE FROM $table WHERE workflow_id = ?${keep.isEmpty ? '' : ' AND id NOT IN (${keep.join(',')})'}',
      [workflowId],
    );
  }

  Future<Response> _create(Request request) async {
    access.require(_user(request), 'add', 'workflow');
    final body = await readBody(request);
    final name = body['name']?.toString().trim() ?? '';
    if (name.isEmpty) throw ApiError.badRequest({'name': ['This field is required.']});
    db.execute('BEGIN;');
    try {
      db.execute('INSERT INTO workflows (name, sort_order, enabled) VALUES (?, ?, ?)',
          [name, asInt(body['order']) ?? 0, body.containsKey('enabled') ? (asBool(body['enabled']) ? 1 : 0) : 1]);
      final id = db.lastInsertRowId;
      _syncChildren(id, 'workflow_triggers', body['triggers'] ?? [], _triggerDefaults, _validateTrigger);
      _syncChildren(id, 'workflow_actions', body['actions'] ?? [], _actionDefaults, _validateAction);
      db.execute('COMMIT;');
      return json(_serializeWorkflow(db.select('SELECT * FROM workflows WHERE id = ?', [id]).first), status: 201);
    } on SqliteException catch (e) {
      db.execute('ROLLBACK;');
      if (e.extendedResultCode == 2067) throw ApiError.badRequest({'name': ['Workflow with this name already exists.']});
      rethrow;
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  Future<Response> _update(Request request) async {
    access.require(_user(request), 'change', 'workflow');
    final row = _require(request);
    final id = row['id'] as int;
    final body = await readBody(request);
    db.execute('BEGIN;');
    try {
      final name = body['name']?.toString().trim();
      db.execute(
        'UPDATE workflows SET name = COALESCE(?, name), sort_order = COALESCE(?, sort_order), '
        'enabled = COALESCE(?, enabled) WHERE id = ?',
        [
          (name?.isEmpty ?? true) ? null : name,
          asInt(body['order']),
          body.containsKey('enabled') ? (asBool(body['enabled']) ? 1 : 0) : null,
          id,
        ],
      );
      if (body.containsKey('triggers')) {
        _syncChildren(id, 'workflow_triggers', body['triggers'], _triggerDefaults, _validateTrigger);
      }
      if (body.containsKey('actions')) {
        _syncChildren(id, 'workflow_actions', body['actions'], _actionDefaults, _validateAction);
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
    return json(_serializeWorkflow(db.select('SELECT * FROM workflows WHERE id = ?', [id]).first));
  }

  Response _delete(Request request) {
    access.require(_user(request), 'delete', 'workflow');
    db.execute('DELETE FROM workflows WHERE id = ?', [_require(request)['id']]);
    return Response(204);
  }

  Response _children(Request request, String table, Map<String, Object?> defaults) {
    access.require(_user(request), 'view', 'workflow');
    final rows = db.select('SELECT id, data FROM $table ORDER BY id');
    return paginated(
      request,
      (limit, offset) => [
        for (final r in rows.skip(offset).take(limit))
          {...defaults, ...jsonDecode(r['data'] as String) as Map<String, dynamic>, 'id': r['id']},
      ],
      allIds: [for (final r in rows) r['id'] as int],
    );
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/workflows/', _list);
    route('POST', '/api/workflows/', _create);
    route('GET', '/api/workflows/<id|[0-9]+>/', _get);
    route('PUT', '/api/workflows/<id|[0-9]+>/', _update);
    route('PATCH', '/api/workflows/<id|[0-9]+>/', _update);
    route('DELETE', '/api/workflows/<id|[0-9]+>/', _delete);
    route('GET', '/api/workflow_triggers/', (Request r) => _children(r, 'workflow_triggers', _triggerDefaults));
    route('GET', '/api/workflow_actions/', (Request r) => _children(r, 'workflow_actions', _actionDefaults));
  }
}

class _Workflow {
  _Workflow(this.id, this.name, this.triggers, this.actions);
  final int id;
  final String name;
  final List<Map<String, dynamic>> triggers;
  final List<Map<String, dynamic>> actions;
}
