import 'dart:io';

import 'package:path/path.dart' as p;

/// Ablage für Originale, Archiv-PDFs und Vorschaubilder.
///
/// Pfade sind relativ (z. B. `originals/0000001.pdf`), damit sich das
/// Backend später austauschen lässt (S3, WebDAV …).
abstract class BlobStore {
  Future<void> put(String key, File source);
  Future<File?> get(String key);
  Future<void> delete(String key);

  /// Datei umbenennen bzw. verschieben.
  Future<void> move(String from, String to) async {
    final f = await get(from);
    if (f == null) throw StateError('Datei $from fehlt');
    final tmp = await File('${Directory.systemTemp.path}/paperbuddy-move-${DateTime.now().microsecondsSinceEpoch}').create();
    await f.copy(tmp.path);
    await put(to, tmp);
    await tmp.delete();
    await delete(from);
  }

  Future<bool> exists(String key) async => await get(key) != null;
}

class LocalBlobStore extends BlobStore {
  LocalBlobStore(this.root);
  final String root;

  String _resolve(String key) {
    final full = p.normalize(p.join(root, key));
    if (!p.isWithin(root, full)) {
      throw ArgumentError('Ungültiger Speicherpfad: $key');
    }
    return full;
  }

  @override
  Future<void> put(String key, File source) async {
    final target = File(_resolve(key));
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }

  @override
  Future<File?> get(String key) async {
    final file = File(_resolve(key));
    return await file.exists() ? file : null;
  }

  @override
  Future<void> delete(String key) async {
    final file = File(_resolve(key));
    if (await file.exists()) await file.delete();
    await _removeEmptyParents(file.parent);
  }

  @override
  Future<void> move(String from, String to) async {
    final source = File(_resolve(from));
    final target = File(_resolve(to));
    await target.parent.create(recursive: true);
    await source.rename(target.path);
    await _removeEmptyParents(source.parent);
  }

  @override
  Future<bool> exists(String key) => File(_resolve(key)).exists();

  /// Leere Ordner nach dem Verschieben aufräumen (nicht die Wurzel).
  Future<void> _removeEmptyParents(Directory dir) async {
    var current = dir;
    while (p.isWithin(root, current.path) && await current.exists()) {
      if (!await current.list().isEmpty) return;
      await current.delete();
      current = current.parent;
    }
  }
}
