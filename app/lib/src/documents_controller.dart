import 'package:flutter/foundation.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

/// Seitenweises Laden der Dokumentliste für einen Filter.
class DocumentsController extends ChangeNotifier {
  DocumentsController(this._client, {this._filter = const DocumentFilter()});

  final PaperlessClient _client;
  static const pageSize = 50;

  DocumentFilter _filter;
  DocumentFilter get filter => _filter;

  final List<Document> items = [];
  int total = 0;
  int _page = 0;
  bool hasMore = true;
  bool loading = false;
  String? error;

  /// Verhindert, dass eine alte Antwort eine neuere Suche überschreibt.
  int _generation = 0;

  Future<void> setFilter(DocumentFilter filter) async {
    if (filter == _filter && items.isNotEmpty) return;
    _filter = filter;
    await refresh(keepItems: false);
  }

  /// Lädt neu. Mit [keepItems] bleibt die bisherige Liste sichtbar, bis die
  /// neue da ist (kein Aufblitzen, Scrollposition bleibt); es werden so
  /// viele Einträge geholt wie bisher geladen waren (höchstens 200).
  Future<void> refresh({bool keepItems = true}) async {
    final generation = ++_generation;
    if (!keepItems || items.isEmpty) {
      items.clear();
      total = 0;
      _page = 0;
      hasMore = true;
      error = null;
      loading = false;
      notifyListeners();
      await loadMore();
      return;
    }
    final size = ((items.length / pageSize).ceil() * pageSize).clamp(
      pageSize,
      200,
    );
    try {
      final result = await _client.documents(
        filter: _filter,
        page: 1,
        pageSize: size,
      );
      if (generation != _generation) return;
      items
        ..clear()
        ..addAll(result.results);
      total = result.count;
      // Danach weiter seitenweise in normaler Größe; eine angebrochene Seite
      // wird erneut geholt, Doppelte filtert loadMore heraus.
      _page = result.results.length ~/ pageSize;
      hasMore = result.hasNext;
      error = null;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      error = e.message;
    }
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await _client.documents(
        filter: _filter,
        page: _page + 1,
        pageSize: pageSize,
      );
      if (generation != _generation) return;
      _page++;
      final known = {for (final d in items) d.id};
      items.addAll(result.results.where((d) => !known.contains(d.id)));
      total = result.count;
      hasMore = result.hasNext;
    } on ApiException catch (e) {
      if (generation != _generation) return;
      error = e.message;
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void replace(Document doc) {
    final i = items.indexWhere((d) => d.id == doc.id);
    if (i >= 0) {
      items[i] = doc;
      notifyListeners();
    }
  }

  void remove(int id) {
    final before = items.length;
    items.removeWhere((d) => d.id == id);
    if (items.length != before) {
      total--;
      notifyListeners();
    }
  }
}
