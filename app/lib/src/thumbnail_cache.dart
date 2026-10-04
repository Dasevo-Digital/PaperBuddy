import 'dart:typed_data';

import 'package:paperbuddy_api/paperbuddy_api.dart';

/// Vorschaubilder im Speicher. Sie werden über den API-Client geladen,
/// weil `Image.network` im Browser keine Auth-Header mitschickt.
class ThumbnailCache {
  ThumbnailCache({this.maxEntries = 300});

  final int maxEntries;
  final _entries = <int, Future<Uint8List?>>{};

  Future<Uint8List?> get(PaperlessClient client, int documentId) {
    final existing = _entries.remove(documentId);
    if (existing != null) {
      _entries[documentId] = existing; // als zuletzt benutzt markieren
      return existing;
    }
    final future = client
        .thumbnail(documentId)
        .then<Uint8List?>(
          (b) => b,
          onError: (_) {
            // Fehlende Vorschau nicht dauerhaft merken (kann nachträglich entstehen).
            _entries.remove(documentId);
            return null;
          },
        );
    _entries[documentId] = future;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  void evict(int documentId) => _entries.remove(documentId);
  void clear() => _entries.clear();
}
