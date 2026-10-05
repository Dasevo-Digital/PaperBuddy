import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../api/http_utils.dart';
import '../db.dart';
import '../storage.dart';
import 'consumer.dart';
import 'tools.dart';

final _log = Logger('pdf');

/// Seiten drehen, löschen, Dokumente zusammenführen und teilen
/// (Bulk-Edit-Methoden `rotate`, `delete_pages`, `merge`, `split`).
class PdfOperations {
  PdfOperations({required this.db, required this.store, required this.tools, required this.consumer, required this.workDir});

  final Database db;
  final BlobStore store;
  final ExternalTools tools;
  final Consumer consumer;
  final String workDir;

  Row _doc(int id) =>
      db.select('SELECT * FROM documents WHERE id = ?', [id]).firstOrNull ??
      (throw ApiError.badRequest({'documents': ['Document $id does not exist.']}));

  Future<Directory> _scratch(String name) =>
      Directory(p.join(workDir, 'pdf', '$name-${DateTime.now().microsecondsSinceEpoch}')).create(recursive: true);

  /// Lokale Kopie einer gespeicherten Datei.
  Future<File> _local(String key, Directory dir, String name) async {
    final f = await store.get(key) ?? (throw StateError('Datei $key fehlt'));
    return f.copy(p.join(dir.path, name));
  }

  /// Wendet [transform] auf Original (falls PDF) und Archiv-PDF an und
  /// aktualisiert danach Text, Seitenzahl, Vorschau und Prüfsumme.
  Future<void> _transform(int id, Future<void> Function(String input, String output) transform) async {
    final d = _doc(id);
    final isPdf = d['mime_type'] == 'application/pdf';
    final archiveKey = d['archive_path'] as String?;
    if (!isPdf && archiveKey == null) {
      throw ApiError.badRequest({'documents': ['Document $id is not a PDF.']});
    }
    final dir = await _scratch('doc$id');
    try {
      String? newChecksum;
      String? textSource;
      if (isPdf) {
        final input = await _local(d['original_path'] as String, dir, 'original.pdf');
        final output = p.join(dir.path, 'original-neu.pdf');
        await transform(input.path, output);
        newChecksum = md5.convert(await File(output).readAsBytes()).toString();
        final dup = db.select('SELECT id FROM documents WHERE checksum = ? AND id <> ?', [newChecksum, id]).firstOrNull;
        if (dup != null) throw ApiError.badRequest({'documents': ['Result is identical to document #${dup['id']}.']});
        await store.put(d['original_path'] as String, File(output));
        textSource = output;
      }
      if (archiveKey != null) {
        final input = await _local(archiveKey, dir, 'archive.pdf');
        final output = p.join(dir.path, 'archive-neu.pdf');
        await transform(input.path, output);
        await store.put(archiveKey, File(output));
        textSource = output;
      }
      final content = textSource == null ? null : await tools.pdfText(textSource);
      final pages = textSource == null ? null : await tools.pdfPageCount(textSource);
      String? thumbKey = d['thumbnail_path'] as String?;
      if (textSource != null) {
        final thumb = p.join(dir.path, 'thumb.png');
        if (await tools.pdfThumbnail(textSource, thumb)) {
          thumbKey = 'thumbnails/${id.toString().padLeft(7, '0')}.png';
          await store.put(thumbKey, File(thumb));
        }
      }
      db.execute(
        'UPDATE documents SET checksum = COALESCE(?, checksum), content = COALESCE(?, content), '
        'page_count = COALESCE(?, page_count), thumbnail_path = ?, modified = ? WHERE id = ?',
        [newChecksum, content?.replaceAll('\f', '\n').trim(), pages, thumbKey, nowIso(), id],
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> rotate(List<int> ids, int degrees) async {
    if (![90, 180, 270, -90].contains(degrees)) {
      throw ApiError.badRequest({'degrees': ['Expected 90, 180 or 270.']});
    }
    for (final id in ids) {
      await consumer.runExclusive(() => _transform(id, (i, o) => tools.qpdf([i, '--rotate=${degrees > 0 ? '+' : ''}$degrees', '--', o])));
    }
    _log.info('${ids.length} Dokument(e) um $degrees° gedreht');
  }

  Future<void> deletePages(int id, List<int> pages) async {
    final total = (_doc(id)['page_count'] as int?) ?? 0;
    final remove = pages.toSet();
    if (remove.isEmpty) return;
    if (total > 0 && remove.any((n) => n < 1 || n > total)) {
      throw ApiError.badRequest({'pages': ['Pages must be between 1 and $total.']});
    }
    await consumer.runExclusive(() => _transform(id, (input, output) async {
          final count = total > 0 ? total : (await tools.pdfPageCount(input) ?? 0);
          final keep = [for (var n = 1; n <= count; n++) if (!remove.contains(n)) n];
          if (keep.isEmpty) throw ApiError.badRequest({'pages': ['Cannot delete all pages.']});
          await tools.qpdf([input, '--pages', input, keep.join(','), '--', output]);
        }));
  }

  /// PDF-Quelle eines Dokuments: Archiv, sonst Original (falls PDF).
  Future<File?> _pdfOf(Row d, Directory dir, {required bool archiveFallback}) async {
    final archive = d['archive_path'] as String?;
    if (archive != null) return _local(archive, dir, '${d['id']}-a.pdf');
    if (d['mime_type'] == 'application/pdf') return _local(d['original_path'] as String, dir, '${d['id']}-o.pdf');
    return null;
  }

  ConsumeOverrides _metadataFrom(Row d, {String? title}) => ConsumeOverrides(
        title: title ?? d['title'] as String,
        created: DateTime.tryParse(d['created'] as String),
        correspondent: d['correspondent_id'] as int?,
        documentType: d['document_type_id'] as int?,
        storagePath: d['storage_path_id'] as int?,
        owner: d['owner'] as int?,
        tags: [
          for (final r in db.select('SELECT tag_id FROM document_tags WHERE document_id = ?', [d['id']])) r['tag_id'] as int,
        ],
      );

  /// Führt mehrere Dokumente zu einem neuen zusammen. Liefert die Task-ID.
  Future<String> merge(List<int> ids, {int? metadataDocument, bool deleteOriginals = false, void Function(List<int>)? trash}) async {
    if (ids.length < 2) throw ApiError.badRequest({'documents': ['At least two documents are required.']});
    final docs = [for (final id in ids) _doc(id)];
    final dir = await _scratch('merge');
    final inputs = <String>[];
    for (final d in docs) {
      final f = await _pdfOf(d, dir, archiveFallback: true);
      if (f == null) throw ApiError.badRequest({'documents': ['Document ${d['id']} has no PDF version.']});
      inputs.add(f.path);
    }
    final out = p.join(dir.path, 'merged.pdf');
    await tools.qpdf(['--empty', '--pages', ...inputs, '--', out]);
    final meta = metadataDocument == null ? null : docs.where((d) => d['id'] == metadataDocument).firstOrNull;
    final overrides = meta == null ? ConsumeOverrides(owner: docs.first['owner'] as int?) : _metadataFrom(meta);
    final task = await consumer.submit(File(out),
        originalName: '${meta?['title'] ?? docs.first['title']} (zusammengeführt).pdf', overrides: overrides, moveSource: true);
    if (deleteOriginals) {
      await consumer.waitFor(task);
      if (_succeeded(task)) trash?.call(ids);
    }
    await dir.delete(recursive: true);
    return task;
  }

  bool _succeeded(String task) =>
      db.select('SELECT status FROM tasks WHERE task_id = ?', [task]).firstOrNull?['status'] == 'SUCCESS';

  /// Teilt ein Dokument nach Seitenbereichen, z. B. `[[1, 2], [3], [4, 5]]`.
  Future<List<String>> split(int id, List<List<int>> ranges, {bool deleteOriginal = false, void Function(List<int>)? trash}) async {
    if (ranges.length < 2) throw ApiError.badRequest({'pages': ['At least two parts are required.']});
    final d = _doc(id);
    final dir = await _scratch('split$id');
    final source = await _pdfOf(d, dir, archiveFallback: true) ??
        (throw ApiError.badRequest({'documents': ['Document $id has no PDF version.']}));
    final total = await tools.pdfPageCount(source.path) ?? (d['page_count'] as int? ?? 0);
    final tasks = <String>[];
    for (final (i, range) in ranges.indexed) {
      if (range.isEmpty || range.any((n) => n < 1 || (total > 0 && n > total))) {
        throw ApiError.badRequest({'pages': ['Invalid page range ${range.join(',')}.']});
      }
      final out = p.join(dir.path, 'teil${i + 1}.pdf');
      await tools.qpdf([source.path, '--pages', source.path, range.join(','), '--', out]);
      tasks.add(await consumer.submit(File(out),
          originalName: '${d['title']} (Teil ${i + 1}).pdf',
          overrides: _metadataFrom(d, title: '${d['title']} (Teil ${i + 1})'),
          moveSource: true));
    }
    if (deleteOriginal) {
      for (final t in tasks) {
        await consumer.waitFor(t);
      }
      if (tasks.every(_succeeded)) trash?.call([id]);
    }
    await dir.delete(recursive: true);
    return tasks;
  }

  /// `"1,2-3,4"` bzw. `[[1],[2,3],[4]]` → Liste von Seitenlisten.
  static List<List<int>> parseRanges(Object? raw) {
    if (raw is List) {
      return [for (final r in raw) r is List ? asIntList(r) : _range('$r')];
    }
    return [for (final part in '$raw'.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) _range(part)];
  }

  static List<int> _range(String s) {
    final m = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(s);
    if (m != null) {
      final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      return [for (var n = a; n <= b; n++) n];
    }
    final n = int.tryParse(s) ?? (throw ApiError.badRequest({'pages': ['Invalid page range: $s']}));
    return [n];
  }
}
