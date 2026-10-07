import 'dart:typed_data';

import 'package:paperbuddy_api/paperbuddy_api.dart';

import 'file_cache.dart';

/// Vorschaubilder im Speicher und – falls vorhanden – auf dem Gerät
/// ([disk]), damit sie nach einem Neustart nicht erneut geladen werden.
/// Sie werden über den API-Client geladen, weil `Image.network` im Browser
/// keine Auth-Header mitschickt.
class ThumbnailCache {
  ThumbnailCache({this.maxEntries = 300});

  final int maxEntries;
  final _entries = <int, Future<Uint8List?>>{};
  FileCache? disk;

  /// [modified] bindet die gespeicherte Vorschau an die Fassung des Dokuments.
  Future<Uint8List?> get(
    PaperlessClient client,
    int documentId, {
    DateTime? modified,
  }) {
    final existing = _entries.remove(documentId);
    if (existing != null) {
      _entries[documentId] = existing; // als zuletzt benutzt markieren
      return existing;
    }
    final future = _load(client, documentId, modified);
    _entries[documentId] = future;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  Future<Uint8List?> _load(
    PaperlessClient client,
    int documentId,
    DateTime? modified,
  ) async {
    final cached = await disk?.thumbnail(documentId, modified);
    if (cached != null) return cached;
    try {
      final bytes = await client.thumbnail(documentId);
      disk?.storeThumbnail(documentId, modified, bytes).ignore();
      return bytes;
    } catch (_) {
      // Fehlende Vorschau nicht dauerhaft merken (kann nachträglich entstehen).
      _entries.remove(documentId);
      return null;
    }
  }

  void evict(int documentId) => _entries.remove(documentId);
  void clear() => _entries.clear();
}
