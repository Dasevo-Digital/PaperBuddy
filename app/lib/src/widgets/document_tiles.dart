import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import 'document_thumbnail.dart';
import 'highlight_text.dart';
import 'tag_chip.dart';

String _subtitle(AppState state, Document d) => [
  ?state.correspondents[d.correspondent]?.name,
  formatDay(d.created),
  ?state.documentTypes[d.documentType]?.name,
].join(' · ');

List<Tag> _tags(AppState state, Document d) => [
  for (final id in d.tags) ?state.tags[id],
];

/// Zeile für die Listenansicht.
class DocumentListTile extends StatelessWidget {
  const DocumentListTile({
    super.key,
    required this.document,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final Document document;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final tags = _tags(state, document);
    final hit = document.searchHit?.highlights ?? '';
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? theme.colorScheme.secondaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 56,
                height: 74,
                child: selected
                    ? ColoredBox(
                        color: theme.colorScheme.primary,
                        child: Icon(
                          LucideIcons.check,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : DocumentThumbnail(documentId: document.id),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(state, document),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (hit.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    HighlightText(hit),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [for (final t in tags) TagChip(tag: t)],
                    ),
                  ],
                ],
              ),
            ),
            if (document.archiveSerialNumber != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '#${document.archiveSerialNumber}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Karte für die Rasteransicht.
class DocumentGridCard extends StatelessWidget {
  const DocumentGridCard({
    super.key,
    required this.document,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final Document document;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final tags = _tags(state, document);
    return Card(
      color: selected ? theme.colorScheme.secondaryContainer : null,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DocumentThumbnail(documentId: document.id),
                  if (selected)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: theme.colorScheme.primary,
                        child: Icon(
                          LucideIcons.check,
                          size: 16,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(state, document),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 18,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final t in tags)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: TagChip(tag: t),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
