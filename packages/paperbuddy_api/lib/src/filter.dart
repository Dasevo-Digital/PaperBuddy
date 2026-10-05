import 'admin_models.dart';

/// Filter und Sortierung für die Dokumentliste.
///
/// Wird in Query-Parameter der Paperless-API übersetzt.
class DocumentFilter {
  const DocumentFilter({
    this.query = '',
    this.tagsAll = const {},
    this.correspondents = const {},
    this.documentTypes = const {},
    this.inboxOnly = false,
    this.createdFrom,
    this.createdTo,
    this.ordering = DocumentOrdering.createdDesc,
  });

  /// Volltextsuche.
  final String query;

  /// Dokument muss alle diese Tags haben.
  final Set<int> tagsAll;

  /// Einer dieser Korrespondenten.
  final Set<int> correspondents;

  /// Einer dieser Dokumenttypen.
  final Set<int> documentTypes;
  final bool inboxOnly;
  final DateTime? createdFrom;
  final DateTime? createdTo;
  final DocumentOrdering ordering;

  bool get isEmpty =>
      query.trim().isEmpty &&
      tagsAll.isEmpty &&
      correspondents.isEmpty &&
      documentTypes.isEmpty &&
      !inboxOnly &&
      createdFrom == null &&
      createdTo == null;

  int get activeFilterCount =>
      (tagsAll.isEmpty ? 0 : 1) +
      (correspondents.isEmpty ? 0 : 1) +
      (documentTypes.isEmpty ? 0 : 1) +
      (inboxOnly ? 1 : 0) +
      (createdFrom == null && createdTo == null ? 0 : 1);

  DocumentFilter copyWith({
    String? query,
    Set<int>? tagsAll,
    Set<int>? correspondents,
    Set<int>? documentTypes,
    bool? inboxOnly,
    DateTime? Function()? createdFrom,
    DateTime? Function()? createdTo,
    DocumentOrdering? ordering,
  }) => DocumentFilter(
    query: query ?? this.query,
    tagsAll: tagsAll ?? this.tagsAll,
    correspondents: correspondents ?? this.correspondents,
    documentTypes: documentTypes ?? this.documentTypes,
    inboxOnly: inboxOnly ?? this.inboxOnly,
    createdFrom: createdFrom == null ? this.createdFrom : createdFrom(),
    createdTo: createdTo == null ? this.createdTo : createdTo(),
    ordering: ordering ?? this.ordering,
  );

  /// Nur die Suche behalten, alle anderen Filter zurücksetzen.
  DocumentFilter clearFilters() =>
      DocumentFilter(query: query, ordering: ordering);

  Map<String, String> toQueryParameters() {
    String day(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final q = query.trim();
    return {
      if (q.isNotEmpty) 'query': q,
      if (tagsAll.isNotEmpty) 'tags__id__all': tagsAll.join(','),
      if (correspondents.isNotEmpty)
        'correspondent__id__in': correspondents.join(','),
      if (documentTypes.isNotEmpty)
        'document_type__id__in': documentTypes.join(','),
      if (inboxOnly) 'is_in_inbox': 'true',
      if (createdFrom != null) 'created__date__gte': day(createdFrom!),
      if (createdTo != null) 'created__date__lte': day(createdTo!),
      // Bei einer Suche sortiert der Server nach Relevanz, außer es ist
      // ausdrücklich etwas anderes gewählt.
      if (q.isEmpty || ordering != DocumentOrdering.createdDesc)
        'ordering': ordering.apiValue,
    };
  }

  /// Regeln für gespeicherte Ansichten (Typen wie `FILTER_*` in Paperless-ngx).
  List<FilterRule> toFilterRules() {
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    final q = query.trim();
    return [
      if (q.isNotEmpty) FilterRule(FilterRuleType.fulltextQuery, q),
      for (final t in tagsAll) FilterRule(FilterRuleType.hasTagsAll, '$t'),
      for (final c in correspondents)
        FilterRule(FilterRuleType.hasCorrespondentAny, '$c'),
      for (final d in documentTypes)
        FilterRule(FilterRuleType.hasDocumentTypeAny, '$d'),
      if (inboxOnly) const FilterRule(FilterRuleType.isInInbox, 'true'),
      // Paperless vergleicht „nach“/„vor“ exklusiv.
      if (createdFrom != null)
        FilterRule(
          FilterRuleType.createdAfter,
          day(createdFrom!.subtract(const Duration(days: 1))),
        ),
      if (createdTo != null)
        FilterRule(
          FilterRuleType.createdBefore,
          day(createdTo!.add(const Duration(days: 1))),
        ),
    ];
  }

  /// Filter aus einer gespeicherten Ansicht. Unbekannte Regeln entfallen.
  factory DocumentFilter.fromSavedView(SavedView view) {
    final tags = <int>{}, correspondents = <int>{}, types = <int>{};
    var query = '';
    var inbox = false;
    DateTime? from, to;
    for (final r in view.rules) {
      final v = r.value;
      final id = int.tryParse(v ?? '');
      switch (r.type) {
        case FilterRuleType.fulltextQuery || FilterRuleType.titleContent:
          query = v ?? '';
        case FilterRuleType.hasTagsAll:
          if (id != null) tags.add(id);
        case FilterRuleType.hasCorrespondentAny || FilterRuleType.correspondent:
          if (id != null) correspondents.add(id);
        case FilterRuleType.hasDocumentTypeAny || FilterRuleType.documentType:
          if (id != null) types.add(id);
        case FilterRuleType.isInInbox:
          inbox = v != 'false';
        case FilterRuleType.createdAfter:
          from = DateTime.tryParse(v ?? '')?.add(const Duration(days: 1));
        case FilterRuleType.createdBefore:
          to = DateTime.tryParse(v ?? '')?.subtract(const Duration(days: 1));
      }
    }
    final sort = '${view.sortReverse ? '-' : ''}${view.sortField ?? 'created'}';
    return DocumentFilter(
      query: query,
      tagsAll: tags,
      correspondents: correspondents,
      documentTypes: types,
      inboxOnly: inbox,
      createdFrom: from,
      createdTo: to,
      ordering: DocumentOrdering.values.firstWhere(
        (o) => o.apiValue == sort,
        orElse: () => DocumentOrdering.createdDesc,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DocumentFilter &&
      other.query == query &&
      _setEq(other.tagsAll, tagsAll) &&
      _setEq(other.correspondents, correspondents) &&
      _setEq(other.documentTypes, documentTypes) &&
      other.inboxOnly == inboxOnly &&
      other.createdFrom == createdFrom &&
      other.createdTo == createdTo &&
      other.ordering == ordering;

  @override
  int get hashCode => Object.hash(
    query,
    Object.hashAllUnordered(tagsAll),
    Object.hashAllUnordered(correspondents),
    Object.hashAllUnordered(documentTypes),
    inboxOnly,
    createdFrom,
    createdTo,
    ordering,
  );

  static bool _setEq(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);
}

enum DocumentOrdering {
  createdDesc('-created', 'Belegdatum, neueste zuerst'),
  createdAsc('created', 'Belegdatum, älteste zuerst'),
  addedDesc('-added', 'Hinzugefügt, neueste zuerst'),
  titleAsc('title', 'Titel A–Z'),
  correspondentAsc('correspondent__name', 'Korrespondent A–Z'),
  asnAsc('archive_serial_number', 'Archivnummer');

  const DocumentOrdering(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

/// Regeltypen gespeicherter Ansichten (Paperless-ngx `FILTER_*`).
abstract final class FilterRuleType {
  static const title = 0;
  static const content = 1;
  static const correspondent = 3;
  static const documentType = 4;
  static const isInInbox = 5;
  static const hasTagsAll = 6;
  static const createdBefore = 8;
  static const createdAfter = 9;
  static const doesNotHaveTag = 17;
  static const titleContent = 19;
  static const fulltextQuery = 20;
  static const hasTagsAny = 22;
  static const hasCorrespondentAny = 26;
  static const hasDocumentTypeAny = 28;
}
