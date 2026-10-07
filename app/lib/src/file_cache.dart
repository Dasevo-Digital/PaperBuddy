import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

/// Eintrag eines offline verfügbaren Dokuments: genug, um es ohne Server
/// in einer Liste zu zeigen und zu öffnen.
class OfflineDocument {
  const OfflineDocument({
    required this.id,
    required this.title,
    required this.created,
    required this.fileName,
    required this.mimeType,
    this.modified,
  });

  final int id;
  final String title;
  final DateTime created;
  final String fileName;
  final String mimeType;
  final DateTime? modified;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'created': created.toIso8601String(),
    'file_name': fileName,
    'mime_type': mimeType,
    'modified': modified?.toIso8601String(),
  };

  factory OfflineDocument.fromJson(Map<String, dynamic> j) => OfflineDocument(
    id: j['id'] as int,
    title: j['title'] as String,
    created: DateTime.parse(j['created'] as String),
    fileName: j['file_name'] as String,
    mimeType: j['mime_type'] as String,
    modified: j['modified'] == null
        ? null
        : DateTime.tryParse(j['modified'] as String),
  );
}

/// Zwischenspeicher auf dem Gerät, getrennt je Server und Benutzer:
///
/// * Vorschaubilder (an die Änderungszeit des Dokuments gebunden),
/// * zuletzt geöffnete Dokumente (höchstens [maxRecentBytes], älteste zuerst
///   entfernt),
/// * offline markierte Dokumente samt Titel und Datum, die nie automatisch
///   gelöscht werden.
///
/// Im Web gibt es keinen Dateispeicher; dann ist [open] `null`.
class FileCache {
  FileCache._(this.root);

  final Directory root;

  static const maxRecentBytes = 300 * 1024 * 1024;

  /// Basisordner für Tests (dort gibt es kein path_provider).
  @visibleForTesting
  static Directory? testBase;
  static const maxThumbnailBytes = 100 * 1024 * 1024;

  /// Ordner für [server] und [username]; `null` im Web oder ohne Speicher.
  static Future<FileCache?> open(
    Uri server,
    String username, {
    Directory? base,
  }) async {
    if (kIsWeb) return null;
    try {
      final dir = base ?? testBase ?? await getApplicationSupportDirectory();
      final key = sha256
          .convert(utf8.encode('$server|${username.toLowerCase()}'))
          .toString()
          .substring(0, 16);
      final root = Directory('${dir.path}/cache/$key');
      await root.create(recursive: true);
      return FileCache._(root);
    } catch (_) {
      return null;
    }
  }

  Directory get _thumbs => Directory('${root.path}/thumbs');
  Directory get _recent => Directory('${root.path}/recent');
  Directory get _offline => Directory('${root.path}/offline');

  static String _stamp(DateTime? modified) =>
      '${modified?.millisecondsSinceEpoch ?? 0}';

  // Vorschaubilder ------------------------------------------------------------

  Future<Uint8List?> thumbnail(int id, DateTime? modified) async {
    final f = File('${_thumbs.path}/$id-${_stamp(modified)}');
    try {
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  Future<void> storeThumbnail(
    int id,
    DateTime? modified,
    Uint8List bytes,
  ) async {
    try {
      await _thumbs.create(recursive: true);
      await _removeVariants(_thumbs, id);
      await File('${_thumbs.path}/$id-${_stamp(modified)}').writeAsBytes(bytes);
      await _prune(_thumbs, maxThumbnailBytes);
    } catch (_) {}
  }

  // Dokumente -----------------------------------------------------------------

  static String _variant(bool original) => original ? 'o' : 'a';

  /// Gespeicherte Datei; ohne [modified] (offline) auch eine ältere Fassung.
  Future<DownloadedFile?> document(
    int id, {
    required bool original,
    DateTime? modified,
    bool anyVersion = false,
  }) async {
    for (final dir in [_offline, _recent]) {
      final hit = await _find(dir, id, original, modified, anyVersion);
      if (hit != null) return hit;
    }
    return null;
  }

  Future<DownloadedFile?> _find(
    Directory dir,
    int id,
    bool original,
    DateTime? modified,
    bool anyVersion,
  ) async {
    if (!await dir.exists()) return null;
    final prefix = '$id-${_variant(original)}-';
    final wanted = '$prefix${_stamp(modified)}';
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.last;
      if (e is! File || name.endsWith('.json')) continue;
      if (name == wanted || (anyVersion && name.startsWith(prefix))) {
        try {
          final meta =
              jsonDecode(await File('${e.path}.json').readAsString())
                  as Map<String, dynamic>;
          // Zuletzt benutzt: für das Aufräumen nach Alter.
          await e.setLastModified(DateTime.now());
          return DownloadedFile(
            await e.readAsBytes(),
            meta['file_name'] as String,
            meta['mime_type'] as String,
          );
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  Future<void> storeDocument(
    int id,
    DownloadedFile file, {
    required bool original,
    DateTime? modified,
  }) async {
    try {
      final offline = await isOffline(id);
      final dir = offline ? _offline : _recent;
      await dir.create(recursive: true);
      await _removeVariants(dir, id, variant: _variant(original));
      final path = '${dir.path}/$id-${_variant(original)}-${_stamp(modified)}';
      await File(path).writeAsBytes(file.bytes);
      await File('$path.json').writeAsString(
        jsonEncode({'file_name': file.fileName, 'mime_type': file.mimeType}),
      );
      if (!offline) await _prune(_recent, maxRecentBytes);
    } catch (_) {}
  }

  // Offline markieren ---------------------------------------------------------

  File get _index => File('${_offline.path}/index.json');

  Future<Map<int, OfflineDocument>> offlineDocuments() async {
    try {
      if (!await _index.exists()) return {};
      final list = jsonDecode(await _index.readAsString()) as List;
      return {
        for (final j in list)
          (j as Map<String, dynamic>)['id'] as int: OfflineDocument.fromJson(j),
      };
    } catch (_) {
      return {};
    }
  }

  Future<bool> isOffline(int id) async =>
      (await offlineDocuments()).containsKey(id);

  Future<void> _writeIndex(Map<int, OfflineDocument> docs) async {
    await _offline.create(recursive: true);
    await _index.writeAsString(
      jsonEncode([for (final d in docs.values) d.toJson()]),
    );
  }

  /// Merkt [doc] für offline und speichert [file] dauerhaft.
  Future<void> keepOffline(Document doc, DownloadedFile file) async {
    final docs = await offlineDocuments();
    docs[doc.id] = OfflineDocument(
      id: doc.id,
      title: doc.title,
      created: doc.created,
      fileName: file.fileName,
      mimeType: file.mimeType,
      modified: doc.modified,
    );
    await _writeIndex(docs);
    // Eine schon vorhandene Kopie aus „zuletzt geöffnet“ wird ersetzt.
    await _removeVariants(_recent, doc.id);
    await storeDocument(doc.id, file, original: false, modified: doc.modified);
  }

  Future<void> removeOffline(int id) async {
    final docs = await offlineDocuments()
      ..remove(id);
    await _writeIndex(docs);
    await _removeVariants(_offline, id);
  }

  /// Belegter Speicher (für die Einstellungen).
  Future<int> sizeInBytes() async {
    var total = 0;
    try {
      await for (final e in root.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Leert Vorschaubilder und zuletzt geöffnete Dokumente; offline
  /// markierte bleiben.
  Future<void> clearTemporary() async {
    for (final d in [_thumbs, _recent]) {
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> clearAll() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _removeVariants(Directory dir, int id, {String? variant}) async {
    if (!await dir.exists()) return;
    final prefix = variant == null ? '$id-' : '$id-$variant-';
    await for (final e in dir.list()) {
      if (e is File && e.uri.pathSegments.last.startsWith(prefix)) {
        await e.delete();
      }
    }
  }

  /// Älteste Dateien entfernen, bis [dir] unter [limit] Bytes liegt.
  static Future<void> _prune(Directory dir, int limit) async {
    final files = <(File, int, DateTime)>[];
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) {
        final stat = await e.stat();
        files.add((e, stat.size, stat.modified));
        total += stat.size;
      }
    }
    if (total <= limit) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (f, size, _) in files) {
      if (total <= limit) break;
      if (f.path.endsWith('.json')) continue;
      await f.delete();
      final meta = File('${f.path}.json');
      if (await meta.exists()) await meta.delete();
      total -= size;
    }
  }
}
