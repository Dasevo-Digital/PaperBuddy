import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../documents_controller.dart';
import '../format.dart';
import '../widgets/document_tiles.dart';
import '../widgets/dialogs.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/label_pickers.dart';
import '../widgets/upload_status.dart';
import '../scan/scan_service.dart';
import '../upload_queue.dart';
import 'document_screen.dart';
import 'network_scan_screen.dart';
import 'upload_screen.dart';

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
    _activeView = null;
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

  /// Markierte Dokumente für die Sammelbearbeitung.
  final _selected = <int>{};

  /// Zuletzt gewählte gespeicherte Ansicht (nur zur Hervorhebung).
  int? _activeView;

  void _toggle(int id) => setState(
    () => _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
  );

  void _tap(Document doc) => _selected.isEmpty ? _open(doc) : _toggle(doc.id);

  Future<void> _bulkAction(_BulkAction action) async {
    final ids = _selected.toList();
    final client = _state.client;
    try {
      switch (action) {
        case _BulkAction.addTags || _BulkAction.removeTags:
          final tags = await pickTags(
            context,
            options: _state.tags.values.toList(),
            selected: {},
          );
          if (tags == null || tags.isEmpty) return;
          await client.bulkEdit(ids, 'modify_tags', {
            'add_tags': action == _BulkAction.addTags ? tags.toList() : <int>[],
            'remove_tags': action == _BulkAction.removeTags
                ? tags.toList()
                : <int>[],
          });
        case _BulkAction.correspondent:
          final picked = await pickLabel<Correspondent>(
            context,
            title: 'Korrespondent setzen',
            options: _state.correspondents.values.toList(),
          );
          if (picked == null) return;
          await client.bulkEdit(ids, 'set_correspondent', {
            'correspondent': picked == -1 ? null : picked,
          });
        case _BulkAction.documentType:
          final picked = await pickLabel<DocumentType>(
            context,
            title: 'Dokumenttyp setzen',
            options: _state.documentTypes.values.toList(),
          );
          if (picked == null) return;
          await client.bulkEdit(ids, 'set_document_type', {
            'document_type': picked == -1 ? null : picked,
          });
        case _BulkAction.delete:
          if (!mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(
                ids.length == 1
                    ? '1 Dokument löschen?'
                    : '${ids.length} Dokumente löschen?',
              ),
              content: const Text(
                'Die Dokumente werden in den Papierkorb des Servers verschoben.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Löschen'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await client.bulkEdit(ids, 'delete');
      }
      setState(_selected.clear);
      await _refresh();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// Auswahl: Scannen (Telefon), Datei oder Netzwerkscanner.
  Future<void> _upload() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ScanService.available)
              ListTile(
                leading: const Icon(LucideIcons.scanLine),
                title: const Text('Dokument scannen'),
                subtitle: const Text('Mit Kantenerkennung, mehrere Seiten'),
                onTap: () => Navigator.pop(context, 'scan'),
              ),
            ListTile(
              leading: const Icon(LucideIcons.folderOpen),
              title: const Text('Datei auswählen'),
              subtitle: const Text('PDF, Bild oder Text'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(LucideIcons.printer),
              title: const Text('Am Netzwerkscanner scannen'),
              subtitle: const Text('Scanner im Heimnetz über den Server'),
              onTap: () => Navigator.pop(context, 'network'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'scan':
        await _scan();
      case 'file':
        await _pickFiles();
      case 'network':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const NetworkScanScreen()),
        );
    }
  }

  // Gespeicherte Ansichten ---------------------------------------------------

  Widget _savedViewsRow() {
    final state = AppScope.of(context);
    final user = state.client.user;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final views = state.savedViews;
        final canSave = user.can('add', 'savedview') && !_userFilter.isEmpty;
        if (views.isEmpty && !canSave) return const SizedBox.shrink();
        return SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final v in views)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onLongPress:
                        v.userCanChange && user.can('delete', 'savedview')
                        ? () => _deleteView(v)
                        : null,
                    child: ChoiceChip(
                      avatar: const Icon(LucideIcons.bookmark, size: 16),
                      label: Text(v.name),
                      selected: _activeView == v.id,
                      onSelected: (_) {
                        if (_activeView == v.id) {
                          _search.clear();
                          _applyFilter(widget.baseFilter);
                        } else {
                          _applyView(v);
                        }
                      },
                    ),
                  ),
                ),
              if (canSave)
                ActionChip(
                  avatar: const Icon(LucideIcons.bookmarkPlus, size: 16),
                  label: const Text('Ansicht speichern'),
                  onPressed: _saveView,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _applyView(SavedView view) async {
    final f = DocumentFilter.fromSavedView(view);
    _search.text = f.query;
    await _applyFilter(f);
    setState(() => _activeView = view.id);
  }

  Future<void> _saveView() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ansicht speichern'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'z. B. Offene Rechnungen',
          ),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    final text = name.text.trim();
    name.dispose();
    if (ok != true || text.isEmpty || !mounted) return;
    final filter = _controller.filter.copyWith(query: _search.text);
    final view = await guarded(
      context,
      () => _state.client.createSavedView(text, filter),
    );
    if (view != null) {
      await _state.refreshLabels();
      if (mounted) setState(() => _activeView = view.id);
    }
  }

  Future<void> _deleteView(SavedView view) async {
    final ok = await confirm(
      context,
      title: 'Ansicht „${view.name}“ löschen?',
      action: 'Löschen',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(context, () => _state.client.deleteSavedView(view.id));
    await _state.refreshLabels();
    if (_activeView == view.id && mounted) setState(() => _activeView = null);
  }

  Future<void> _scan() async {
    try {
      final pages = await ScanService.scanPages();
      if (pages == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(
          builder: (_) => UploadScreen.scan(pages: pages),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Scanner nicht verfügbar: $e')));
      }
    }
  }

  /// Eine Datei: mit Metadaten-Bildschirm. Mehrere: direkt in die Warteschlange.
  Future<void> _pickFiles() async {
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
    if (!mounted) return;
    if (files.length == 1) {
      await Navigator.of(context).push(
        MaterialPageRoute<bool>(
          builder: (_) => UploadScreen.file(
            fileName: files.single.name,
            fileBytes: files.single.bytes,
          ),
        ),
      );
      return;
    }
    _state.uploads.add(_state.client, [
      for (final f in files) UploadRequest(f.name, f.bytes),
    ]).ignore();
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
              icon: const Icon(LucideIcons.plus),
              label: const Text('Neu'),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_selected.isNotEmpty)
              _SelectionBar(
                count: _selected.length,
                onClear: () => setState(_selected.clear),
                onSelectAll: () => setState(
                  () => _selected.addAll(_controller.items.map((d) => d.id)),
                ),
                onAction: _bulkAction,
              )
            else
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
            if (!widget.baseFilter.inboxOnly) _savedViewsRow(),
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
                selected: _selected.contains(c.items[i].id),
                onLongPress: () => _toggle(c.items[i].id),
                onTap: () => _tap(c.items[i]),
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
              selected: _selected.contains(c.items[i].id),
              onLongPress: () => _toggle(c.items[i].id),
              onTap: () => _tap(c.items[i]),
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

enum _BulkAction { addTags, removeTags, correspondent, documentType, delete }

/// Ersetzt die Kopfzeile, solange Dokumente markiert sind.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onClear,
    required this.onSelectAll,
    required this.onAction,
  });

  final int count;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;
  final ValueChanged<_BulkAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = AppScope.of(context).client.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Auswahl aufheben',
            icon: const Icon(LucideIcons.x),
            onPressed: onClear,
          ),
          Expanded(
            child: Text('$count ausgewählt', style: theme.textTheme.titleLarge),
          ),
          IconButton(
            tooltip: 'Alle auswählen',
            icon: const Icon(LucideIcons.listChecks),
            onPressed: onSelectAll,
          ),
          if (user.can('change', 'document'))
            IconButton(
              tooltip: 'Tags hinzufügen',
              icon: const Icon(LucideIcons.tag),
              onPressed: () => onAction(_BulkAction.addTags),
            ),
          PopupMenuButton<_BulkAction>(
            tooltip: 'Weitere Aktionen',
            onSelected: onAction,
            itemBuilder: (context) => [
              if (user.can('change', 'document')) ...[
                const PopupMenuItem(
                  value: _BulkAction.removeTags,
                  child: Text('Tags entfernen'),
                ),
                const PopupMenuItem(
                  value: _BulkAction.correspondent,
                  child: Text('Korrespondent setzen'),
                ),
                const PopupMenuItem(
                  value: _BulkAction.documentType,
                  child: Text('Dokumenttyp setzen'),
                ),
              ],
              if (user.can('delete', 'document'))
                const PopupMenuItem(
                  value: _BulkAction.delete,
                  child: Text('Löschen'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
