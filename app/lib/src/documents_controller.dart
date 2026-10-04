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
    await refresh();
  }

  Future<void> refresh() async {
    _generation++;
    items.clear();
    total = 0;
    _page = 0;
    hasMore = true;
    error = null;
    loading = false;
    notifyListeners();
    await loadMore();
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
      items.addAll(result.results);
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
