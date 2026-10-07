import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../file_kinds.dart';
import '../format.dart';
import '../widgets/notification_bell.dart';
import 'document_screen.dart';
import 'documents_screen.dart';
import '../widgets/dialogs.dart';

/// Übersicht mit Kennzahlen wie im Dashboard von Paperless-ngx.
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key, this.onOpenInbox, this.onOpenDocuments});

  final VoidCallback? onOpenInbox;
  final VoidCallback? onOpenDocuments;

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  late final AppState _state;
  Statistics? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _state.documentsChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _state.documentsChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final stats = await _state.client.statistics();
      if (mounted) {
        setState(() {
          _stats = stats;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = _stats;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Übersicht',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  const NotificationBell(),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  // Seiten im IndexedStack teilen sich sonst den Controller.
                  primary: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: stats == null
                            ? Padding(
                                padding: const EdgeInsets.all(48),
                                child: Center(
                                  child: _error == null
                                      ? const CircularProgressIndicator()
                                      : Text(_error!),
                                ),
                              )
                            : StatisticsCard(
                                stats: stats,
                                onOpenInbox: widget.onOpenInbox,
                                onOpenDocuments: widget.onOpenDocuments,
                              ),
                      ),
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: const UpcomingRemindersCard(),
                      ),
                    ),
                    for (final view in AppScope.of(context).savedViews)
                      if (view.showOnDashboard)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: SavedViewCard(
                                key: ValueKey(view.id),
                                view: view,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Karte „Statistiken“: Zähler, Dateitypen als Balken, Ordnungsmerkmale.
class StatisticsCard extends StatelessWidget {
  const StatisticsCard({
    super.key,
    required this.stats,
    this.onOpenInbox,
    this.onOpenDocuments,
  });

  final Statistics stats;
  final VoidCallback? onOpenInbox;
  final VoidCallback? onOpenDocuments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final number = NumberFormat.decimalPattern('de');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Text('Statistiken', style: theme.textTheme.titleLarge),
            _Panel(
              children: [
                if (stats.documentsInbox != null)
                  _CountRow(
                    label: 'Dokumente im Posteingang',
                    value: number.format(stats.documentsInbox),
                    highlight: true,
                    onTap: onOpenInbox,
                  ),
                _CountRow(
                  label: 'Dokumente insgesamt',
                  value: number.format(stats.documentsTotal),
                  highlight: true,
                  onTap: onOpenDocuments,
                ),
                _CountRow(
                  label: 'Zeichen insgesamt',
                  value: number.format(stats.characterCount),
                ),
                if (stats.fileTypes.isNotEmpty) FileTypeBar(stats: stats),
              ],
            ),
            _Panel(
              children: [
                _CountRow(label: 'Tags', value: number.format(stats.tagCount)),
                _CountRow(
                  label: 'Korrespondenten',
                  value: number.format(stats.correspondentCount),
                ),
                _CountRow(
                  label: 'Dokumenttypen',
                  value: number.format(stats.documentTypeCount),
                ),
                _CountRow(
                  label: 'Speicherpfade',
                  value: number.format(stats.storagePathCount),
                ),
                if (stats.currentAsn > 0)
                  _CountRow(
                    label: 'Aktuelle Archivnummer',
                    value: '${stats.currentAsn}',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.label,
    required this.value,
    this.highlight = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // Im Dunkeln kräftiges Grün mit heller Schrift statt des hellen Mint.
    final pill = dark ? strongPrimary(scheme) : scheme.primary;
    final onPill = dark ? Colors.white : scheme.onPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text('$label:', style: theme.textTheme.bodyLarge)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: highlight ? pill : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                value,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: highlight ? onPill : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Anteile der Dateitypen als gestapelter Balken mit Legende.
class FileTypeBar extends StatelessWidget {
  const FileTypeBar({super.key, required this.stats});

  final Statistics stats;

  /// Mehr Typen als hier fasst „Andere“ zusammen.
  static const maxTypes = 5;

  static String label(String mimeType) => FileKinds.label(mimeType);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = stats.fileTypes.fold<int>(0, (s, t) => s + t.count);
    if (total == 0) return const SizedBox.shrink();
    final shown = stats.fileTypes.take(maxTypes).toList();
    final rest = stats.fileTypes
        .skip(maxTypes)
        .fold<int>(0, (s, t) => s + t.count);
    final entries = [
      for (final t in shown) (label: label(t.mimeType), count: t.count),
      if (rest > 0) (label: 'Andere', count: rest),
    ];
    // Abstufungen der Hauptfarbe, dunkler je seltener.
    final base = theme.brightness == Brightness.dark
        ? strongPrimary(scheme)
        : scheme.primary;
    Color colorAt(int i) =>
        Color.lerp(base, scheme.surface, (i * 0.22).clamp(0, 0.8))!;
    final percent = NumberFormat('#0.0', 'de');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  for (var i = 0; i < entries.length; i++)
                    Expanded(
                      flex: (entries[i].count * 1000 ~/ total).clamp(1, 1000),
                      child: Container(
                        margin: EdgeInsets.only(
                          right: i < entries.length - 1 ? 1 : 0,
                        ),
                        color: colorAt(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (var i = 0; i < entries.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: colorAt(i),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: entries[i].label,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(
                            text:
                                ' (${percent.format(entries[i].count * 100 / total)}%)',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Kräftige Variante der Hauptfarbe für dunkle Flächen (Material 3 macht
/// sie im Darkmode sehr hell).
Color strongPrimary(ColorScheme scheme) {
  final hsl = HSLColor.fromColor(scheme.primary);
  return hsl.withSaturation(0.55).withLightness(0.36).toColor();
}

/// Gespeicherte Ansicht als Kachel: die neuesten Dokumente und „Alle
/// anzeigen“, wie die Ansichten auf dem Dashboard von Paperless-ngx.
class SavedViewCard extends StatefulWidget {
  const SavedViewCard({super.key, required this.view});

  final SavedView view;

  /// So viele Dokumente zeigt die Kachel.
  static const count = 5;

  @override
  State<SavedViewCard> createState() => _SavedViewCardState();
}

class _SavedViewCardState extends State<SavedViewCard> {
  late final AppState _state;
  PageResult<Document>? _page;
  String? _error;

  DocumentFilter get _filter => DocumentFilter.fromSavedView(widget.view);

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _state.documentsChanged.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(SavedViewCard old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) _load();
  }

  @override
  void dispose() {
    _state.documentsChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await _state.client.documents(
        filter: _filter,
        pageSize: SavedViewCard.count,
      );
      if (mounted) {
        setState(() {
          _page = page;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = _page;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.bookmark,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.view.name,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (page != null)
                  Text(
                    NumberFormat.decimalPattern('de').format(page.count),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DocumentsScreen(
                        title: widget.view.name,
                        baseFilter: _filter,
                      ),
                    ),
                  ),
                  child: const Text('Alle anzeigen'),
                ),
              ],
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(_error!))
            else if (page == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (page.results.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Keine Dokumente',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              for (final d in page.results)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(right: 8),
                  leading: Icon(FileKinds.icon(d.mimeType), size: 20),
                  title: Text(
                    d.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(formatDay(d.created)),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DocumentScreen(document: d),
                      ),
                    );
                    _load();
                  },
                ),
          ],
        ),
      ),
    );
  }
}

/// Offene Fristen, nächste zuerst; fällige rot. Ohne Fristen unsichtbar.
class UpcomingRemindersCard extends StatefulWidget {
  const UpcomingRemindersCard({super.key});

  static const count = 8;

  @override
  State<UpcomingRemindersCard> createState() => _UpcomingRemindersCardState();
}

class _UpcomingRemindersCardState extends State<UpcomingRemindersCard> {
  late final AppState _state;
  List<Reminder> _open = [];

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _state.documentsChanged.addListener(_load);
    _state.remindersChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _state.documentsChanged.removeListener(_load);
    _state.remindersChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _state.client.reminders(done: false);
      if (mounted) setState(() => _open = list);
    } on ApiException {
      // Älterer Server ohne Fristen: Karte bleibt weg.
    }
  }

  Future<void> _openDocument(Reminder r) async {
    final navigator = Navigator.of(context);
    try {
      final doc = await _state.client.document(r.document);
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => DocumentScreen(document: doc)),
      );
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_open.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                spacing: 8,
                children: [
                  Icon(
                    LucideIcons.alarmClock,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  Text('Fristen', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 4),
              for (final r in _open.take(UpcomingRemindersCard.count))
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(right: 8),
                  title: Text(
                    r.note.isEmpty ? r.documentTitle : r.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: r.note.isEmpty
                      ? null
                      : Text(
                          r.documentTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: Text(
                    formatDay(r.due),
                    style: r.isDue()
                        ? TextStyle(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.bold,
                          )
                        : null,
                  ),
                  onTap: () => _openDocument(r),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
