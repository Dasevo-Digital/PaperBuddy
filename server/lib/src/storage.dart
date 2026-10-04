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
}

class LocalBlobStore implements BlobStore {
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
  }
}
