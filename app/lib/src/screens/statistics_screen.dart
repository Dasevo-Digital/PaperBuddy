import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../widgets/notification_bell.dart';

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
                color: highlight
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                value,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: highlight ? scheme.onPrimary : scheme.onSurfaceVariant,
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

  static String label(String mimeType) => switch (mimeType) {
    'application/pdf' => 'PDF',
    'text/plain' => 'TXT',
    'image/jpeg' => 'JPG',
    'image/png' => 'PNG',
    'image/tiff' => 'TIFF',
    'image/webp' => 'WEBP',
    'image/heic' => 'HEIC',
    'message/rfc822' => 'E-Mail',
    'text/csv' => 'CSV',
    'text/html' => 'HTML',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
      'XLSX',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      'DOCX',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
      'PPTX',
    'application/vnd.oasis.opendocument.text' => 'ODT',
    'application/vnd.oasis.opendocument.spreadsheet' => 'ODS',
    _ => mimeType.split('/').last.toUpperCase(),
  };

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
    Color colorAt(int i) =>
        Color.lerp(scheme.primary, scheme.surface, (i * 0.22).clamp(0, 0.8))!;
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
