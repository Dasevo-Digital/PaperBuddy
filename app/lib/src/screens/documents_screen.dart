import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../documents_controller.dart';
import '../format.dart';
import '../widgets/document_tiles.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/upload_status.dart';
import 'document_screen.dart';

/// Dokumentliste mit Suche, Filtern und Upload.
///
/// [baseFilter] ist fest vorgegeben (z. B. Posteingang) und wird mit den
/// Filtern des Benutzers kombiniert.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({
    super.key,
    required this.title,
    this.baseFilter = const DocumentFilter(),
  });

  final String title;
  final DocumentFilter baseFilter;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

enum _Layout { list, grid }

class _DocumentsScreenState extends State<DocumentsScreen> {
  late final AppState _state;
  late final DocumentsController _controller;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  _Layout? _layout;

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _controller = DocumentsController(_state.client, filter: widget.baseFilter)
      ..refresh();
    _state.documentsChanged.addListener(_controller.refresh);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _state.documentsChanged.removeListener(_controller.refresh);
    _debounce?.cancel();
    _controller.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800) _controller.loadMore();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _applyFilter(_controller.filter),
    );
    setState(() {}); // Löschen-Knopf ein-/ausblenden
  }

  /// Übernimmt [filter] mit dem aktuellen Suchtext und dem festen
  /// [DocumentsScreen.baseFilter]. Der Suchtext kommt immer aus dem Feld,
  /// damit eine noch wartende Eingabe nicht verloren geht oder ein
  /// veralteter Stand zurückkommt.
  Future<void> _applyFilter(DocumentFilter filter) {
    _debounce?.cancel();
    var f = filter.copyWith(query: _search.text);
    if (widget.baseFilter.inboxOnly) f = f.copyWith(inboxOnly: true);
    return _controller.setFilter(f);
  }

  /// Was der Benutzer selbst gefiltert hat, ohne den festen [baseFilter].
  DocumentFilter get _userFilter => widget.baseFilter.inboxOnly
      ? _controller.filter.copyWith(inboxOnly: false)
      : _controller.filter;

  Future<void> _openFilters() async {
    final result = await showFilterSheet(
      context,
      _controller.filter,
      showInboxSwitch: !widget.baseFilter.inboxOnly,
    );
    if (result != null) await _applyFilter(result);
  }

  Future<void> _refresh() async {
    await Future.wait([_controller.refresh(), _state.refreshLabels()]);
  }

  Future<void> _open(Document doc) async {
    final result = await Navigator.of(context).push<DocumentScreenResult>(
      MaterialPageRoute(builder: (_) => DocumentScreen(document: doc)),
    );
    switch (result) {
      case DocumentDeleted(:final id):
        _controller.remove(id);
      case DocumentUpdated(:final document):
        _controller.replace(document);
      case null:
    }
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'tif',
        'tiff',
        'webp',
        'txt',
      ],
    );
    if (picked.isEmpty || !mounted) return;
    final files = [
      for (final f in picked) (name: f.name, bytes: await f.readAsBytes()),
    ];
    _state.uploads.add(_state.client, files);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final layout = _layout ?? (width >= 900 ? _Layout.grid : _Layout.list);
    final canUpload = _state.client.user.can('add', 'document');

    return Scaffold(
      floatingActionButton: canUpload
          ? FloatingActionButton.extended(
              // Mehrere Listen liegen gleichzeitig im IndexedStack.
              heroTag: 'upload-${widget.title}',
              onPressed: _upload,
              icon: const Icon(LucideIcons.upload),
              label: const Text('Hochladen'),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: layout == _Layout.list
                        ? 'Rasteransicht'
                        : 'Listenansicht',
                    icon: Icon(
                      layout == _Layout.list
                          ? LucideIcons.layoutGrid
                          : LucideIcons.list,
                    ),
                    onPressed: () => setState(
                      () => _layout = layout == _Layout.list
                          ? _Layout.grid
                          : _Layout.list,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final count = _userFilter.activeFilterCount;
                  return SearchBar(
                    controller: _search,
                    hintText: 'Volltextsuche',
                    leading: const Icon(LucideIcons.search),
                    elevation: const WidgetStatePropertyAll(0),
                    onChanged: _onSearchChanged,
                    trailing: [
                      if (_search.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Suche löschen',
                          icon: const Icon(LucideIcons.x),
                          onPressed: () {
                            _search.clear();
                            _applyFilter(_controller.filter);
                            setState(() {});
                          },
                        ),
                      IconButton(
                        tooltip: 'Filter',
                        onPressed: _openFilters,
                        icon: Badge(
                          isLabelVisible: count > 0,
                          label: Text('$count'),
                          child: const Icon(LucideIcons.slidersHorizontal),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            _ActiveFilters(
              controller: _controller,
              hideInbox: widget.baseFilter.inboxOnly,
              onChanged: _applyFilter,
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => RefreshIndicator(
                  onRefresh: _refresh,
                  child: _buildList(layout),
                ),
              ),
            ),
            const UploadStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildList(_Layout layout) {
    final c = _controller;
    if (c.items.isEmpty) {
      final Widget child;
      if (c.loading) {
        child = const Center(child: CircularProgressIndicator());
      } else if (c.error != null) {
        child = _Message(
          icon: LucideIcons.cloudOff,
          text: c.error!,
          action: FilledButton.tonal(
            onPressed: c.refresh,
            child: const Text('Erneut versuchen'),
          ),
        );
      } else if (!_userFilter.isEmpty) {
        child = const _Message(
          icon: LucideIcons.searchX,
          text: 'Keine passenden Dokumente gefunden.',
        );
      } else {
        child = _Message(
          icon: widget.baseFilter.inboxOnly
              ? LucideIcons.inbox
              : LucideIcons.fileStack,
          text: widget.baseFilter.inboxOnly
              ? 'Der Posteingang ist leer.'
              : 'Noch keine Dokumente. Lade eins hoch oder lege Scans in den Eingangsordner des Servers.',
        );
      }
      // Scrollbar, damit Ziehen zum Aktualisieren auch hier funktioniert.
      return LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(height: box.maxHeight, child: child),
        ),
      );
    }

    final footer = c.hasMore || c.error != null
        ? Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: c.error != null
                  ? TextButton(
                      onPressed: c.loadMore,
                      child: Text('${c.error} – erneut versuchen'),
                    )
                  : const CircularProgressIndicator(),
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: Text(
              c.total == 1 ? '1 Dokument' : '${c.total} Dokumente',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );

    if (layout == _Layout.grid) {
      return CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                childAspectRatio: 0.62,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: c.items.length,
              itemBuilder: (context, i) => DocumentGridCard(
                document: c.items[i],
                onTap: () => _open(c.items[i]),
              ),
            ),
          ),
          SliverToBoxAdapter(child: footer),
        ],
      );
    }
    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: c.items.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 86),
      itemBuilder: (context, i) => i == c.items.length
          ? footer
          : DocumentListTile(
              document: c.items[i],
              onTap: () => _open(c.items[i]),
            ),
    );
  }
}

/// Aktive Filter als entfernbare Chips unter der Suche.
class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({
    required this.controller,
    required this.onChanged,
    required this.hideInbox,
  });

  final DocumentsController controller;
  final ValueChanged<DocumentFilter> onChanged;
  final bool hideInbox;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final f = controller.filter;
        final chips = <Widget>[
          if (f.inboxOnly && !hideInbox)
            _chip('Posteingang', () => onChanged(f.copyWith(inboxOnly: false))),
          if (f.createdFrom != null)
            _chip(
              '${formatDay(f.createdFrom!)} – ${formatDay(f.createdTo!)}',
              () => onChanged(
                f.copyWith(createdFrom: () => null, createdTo: () => null),
              ),
            ),
          for (final id in f.tagsAll)
            _chip(
              state.tags[id]?.name ?? 'Tag $id',
              () => onChanged(f.copyWith(tagsAll: {...f.tagsAll}..remove(id))),
            ),
          for (final id in f.correspondents)
            _chip(
              state.correspondents[id]?.name ?? 'Korrespondent $id',
              () => onChanged(
                f.copyWith(correspondents: {...f.correspondents}..remove(id)),
              ),
            ),
          for (final id in f.documentTypes)
            _chip(
              state.documentTypes[id]?.name ?? 'Typ $id',
              () => onChanged(
                f.copyWith(documentTypes: {...f.documentTypes}..remove(id)),
              ),
            ),
        ];
        if (chips.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final c in chips)
                Padding(padding: const EdgeInsets.only(right: 6), child: c),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, VoidCallback onDeleted) => InputChip(
    label: Text(label),
    onDeleted: onDeleted,
    deleteIcon: const Icon(LucideIcons.x, size: 16),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
