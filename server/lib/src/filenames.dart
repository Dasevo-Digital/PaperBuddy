import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'storage.dart';

final _log = Logger('filenames');

/// Legt Dateien nach einer Vorlage in Ordnern ab, wie `FILENAME_FORMAT`
/// und Speicherpfade in Paperless-ngx.
///
/// Platzhalter: `{{ title }}`, `{{ correspondent }}`, `{{ document_type }}`,
/// `{{ created }}`, `{{ created_year }}`, `{{ created_month }}`, `{{ created_day }}`,
/// `{{ added_year }}` …, `{{ asn }}`, `{{ tag_list }}`, `{{ owner_username }}`,
/// `{{ original_name }}`, `{{ doc_pk }}`, `{{ custom_fields.Name }}`.
/// Die alte Schreibweise `{created_year}` funktioniert ebenfalls.
class FilenameGenerator {
  FilenameGenerator(this.db, this.store, {this.format});

  final Database db;
  final BlobStore store;

  /// Globale Vorlage; `null` = Dateien nach ID ablegen.
  final String? format;

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// Einzelner Pfadbestandteil ohne Trennzeichen und Sonderzeichen.
  static String sanitize(String value) {
    var v = value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    v = v.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'\s+'), ' ');
    if (v.length > 120) v = v.substring(0, 120).trim();
    return v.isEmpty ? '-none-' : v;
  }

  Map<String, String> _values(Row d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final created = DateTime.parse(d['created'] as String);
    final added = DateTime.parse(d['added'] as String).toLocal();
    final id = d['id'] as int;
    Map<String, String> dates(String prefix, DateTime t) => {
          prefix: '${t.year}-${two(t.month)}-${two(t.day)}',
          '${prefix}_year': '${t.year}',
          '${prefix}_year_short': two(t.year % 100),
          '${prefix}_month': two(t.month),
          '${prefix}_month_name': _months[t.month - 1],
          '${prefix}_month_name_short': _months[t.month - 1].substring(0, 3),
          '${prefix}_day': two(t.day),
        };
    final tags = [
      for (final r in db.select(
          'SELECT t.name FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = ? ORDER BY t.name',
          [id]))
        r['name'] as String,
    ];
    final values = <String, String>{
      'title': d['title'] as String,
      'correspondent': _name('correspondents', d['correspondent_id']),
      'document_type': _name('document_types', d['document_type_id']),
      'asn': d['archive_serial_number'] == null ? '-none-' : '${d['archive_serial_number']}',
      'tag_list': tags.isEmpty ? '-none-' : tags.join(','),
      'owner_username': d['owner'] == null
          ? '-none-'
          : (db.select('SELECT username FROM users WHERE id = ?', [d['owner']]).firstOrNull?['username'] as String? ?? '-none-'),
      'original_name': p.basenameWithoutExtension(d['original_filename'] as String),
      'doc_pk': id.toString().padLeft(7, '0'),
      ...dates('created', created),
      ...dates('added', added),
    };
    for (final r in db.select(
        'SELECT c.name, f.value FROM document_custom_fields f JOIN custom_fields c ON c.id = f.field_id WHERE f.document_id = ?',
        [id])) {
      final v = r['value'] == null ? null : jsonDecode(r['value'] as String);
      values['custom_fields.${r['name']}'] = v == null ? '-none-' : '$v';
    }
    return values;
  }

  String _name(String table, Object? id) => id == null
      ? '-none-'
      : (db.select('SELECT name FROM $table WHERE id = ?', [id]).firstOrNull?['name'] as String? ?? '-none-');

  /// Vorlage für ein Dokument: Speicherpfad vor globalem Format.
  String? templateFor(Row d) {
    final sp = d['storage_path_id'];
    if (sp != null) {
      final path = db.select('SELECT path FROM storage_paths WHERE id = ?', [sp]).firstOrNull?['path'] as String?;
      if (path != null && path.trim().isNotEmpty) return path.trim();
    }
    return format;
  }

  /// Relativer Pfad ohne Endung, z. B. `2026/Stadtwerke/Stromrechnung`.
  String render(String template, Row d) {
    final values = _values(d);
    final rendered = template.replaceAllMapped(
      RegExp(r'\{\{\s*([\w.]+)\s*\}\}|\{([\w.]+)\}'),
      (m) => sanitize(values[m.group(1) ?? m.group(2)] ?? '-none-'),
    );
    final parts = rendered.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty && s != '.' && s != '..');
    return parts.join('/');
  }

  /// Verschiebt Original und Archiv-PDF an den Platz laut Vorlage.
  /// Liefert `true`, wenn sich etwas geändert hat.
  Future<bool> relocate(int id) async {
    final d = db.select('SELECT * FROM documents WHERE id = ?', [id]).firstOrNull;
    if (d == null) return false;
    final template = templateFor(d);
    final base = template == null ? id.toString().padLeft(7, '0') : render(template, d);
    if (base.isEmpty) return false;
    final ext = p.extension(d['original_path'] as String);
    final originalKey = await _unique('originals', base, ext, d['original_path'] as String);
    final archiveKey = d['archive_path'] == null
        ? null
        : await _unique('archive', base, '.pdf', d['archive_path'] as String, column: 'archive_path');
    var changed = false;
    if (originalKey != d['original_path']) {
      await store.move(d['original_path'] as String, originalKey);
      changed = true;
    }
    if (archiveKey != null && archiveKey != d['archive_path']) {
      await store.move(d['archive_path'] as String, archiveKey);
      changed = true;
    }
    if (changed) {
      db.execute('UPDATE documents SET original_path = ?, archive_path = ? WHERE id = ?', [originalKey, archiveKey, id]);
      _log.fine('Dokument #$id → $originalKey');
    }
    return changed;
  }

  /// Freier Name: bei Kollision `_01`, `_02` … anhängen.
  Future<String> _unique(String folder, String base, String ext, String current, {String column = 'original_path'}) async {
    for (var n = 0; n < 1000; n++) {
      final key = '$folder/$base${n == 0 ? '' : '_${n.toString().padLeft(2, '0')}'}$ext';
      if (key == current) return key;
      final taken = db.select('SELECT 1 FROM documents WHERE $column = ?', [key]).isNotEmpty || await store.exists(key);
      if (!taken) return key;
    }
    throw StateError('Kein freier Dateiname für $base');
  }

  /// Alle Dokumente neu ablegen (`manage rename-files`).
  Future<int> relocateAll() async {
    var n = 0;
    for (final r in db.select('SELECT id FROM documents ORDER BY id')) {
      if (await relocate(r['id'] as int)) n++;
    }
    return n;
  }
}
