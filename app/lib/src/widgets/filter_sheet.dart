import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import '../l10n.dart';

/// Öffnet das Filter-Panel und liefert den neuen Filter (oder `null`).
Future<DocumentFilter?> showFilterSheet(
  BuildContext context,
  DocumentFilter filter, {
  bool showInboxSwitch = true,
}) {
  return showModalBottomSheet<DocumentFilter>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        _FilterSheet(initial: filter, showInboxSwitch: showInboxSwitch),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.showInboxSwitch});
  final DocumentFilter initial;
  final bool showInboxSwitch;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late DocumentFilter _f = widget.initial;

  Set<int> _toggle(Set<int> set, int id) =>
      set.contains(id) ? ({...set}..remove(id)) : {...set, id};

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _f.createdFrom != null && _f.createdTo != null
          ? DateTimeRange(start: _f.createdFrom!, end: _f.createdTo!)
          : null,
    );
    if (range != null) {
      setState(
        () => _f = _f.copyWith(
          createdFrom: () => range.start,
          createdTo: () => range.end,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final tags = state.tags.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final correspondents = state.correspondents.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final types = state.documentTypes.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (children.isEmpty)
            Text(
              tr.noneYet,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(spacing: 6, runSpacing: 6, children: children),
        ],
      ),
    );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(tr.filter, style: theme.textTheme.titleLarge),
                ),
                TextButton(
                  onPressed: () => setState(() => _f = _f.clearFilters()),
                  child: Text(tr.reset),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                if (widget.showInboxSwitch)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.inboxOnly),
                    value: _f.inboxOnly,
                    onChanged: (v) =>
                        setState(() => _f = _f.copyWith(inboxOnly: v)),
                  ),
                section(tr.sortOrder, [
                  for (final o in DocumentOrdering.values)
                    ChoiceChip(
                      label: Text(o.label),
                      selected: _f.ordering == o,
                      onSelected: (_) =>
                          setState(() => _f = _f.copyWith(ordering: o)),
                    ),
                ]),
                section(tr.periodDocumentDate, [
                  ActionChip(
                    avatar: const Icon(LucideIcons.calendarRange, size: 16),
                    label: Text(
                      _f.createdFrom == null
                          ? tr.any
                          : '${formatDay(_f.createdFrom!)} – ${formatDay(_f.createdTo!)}',
                    ),
                    onPressed: _pickRange,
                  ),
                  if (_f.createdFrom != null)
                    ActionChip(
                      avatar: const Icon(LucideIcons.x, size: 16),
                      label: Text(tr.remove),
                      onPressed: () => setState(
                        () => _f = _f.copyWith(
                          createdFrom: () => null,
                          createdTo: () => null,
                        ),
                      ),
                    ),
                ]),
                section(tr.tagsAllMustMatch, [
                  for (final t in tags)
                    FilterChip(
                      label: Text('${t.name} (${t.documentCount})'),
                      selected: _f.tagsAll.contains(t.id),
                      avatar: CircleAvatar(
                        backgroundColor: Color(parseHexColor(t.color)),
                        radius: 6,
                      ),
                      onSelected: (_) => setState(
                        () => _f = _f.copyWith(
                          tagsAll: _toggle(_f.tagsAll, t.id),
                        ),
                      ),
                    ),
                ]),
                section(tr.correspondent, [
                  for (final c in correspondents)
                    FilterChip(
                      label: Text('${c.name} (${c.documentCount})'),
                      selected: _f.correspondents.contains(c.id),
                      onSelected: (_) => setState(
                        () => _f = _f.copyWith(
                          correspondents: _toggle(_f.correspondents, c.id),
                        ),
                      ),
                    ),
                ]),
                section(tr.documentType, [
                  for (final d in types)
                    FilterChip(
                      label: Text('${d.name} (${d.documentCount})'),
                      selected: _f.documentTypes.contains(d.id),
                      onSelected: (_) => setState(
                        () => _f = _f.copyWith(
                          documentTypes: _toggle(_f.documentTypes, d.id),
                        ),
                      ),
                    ),
                ]),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _f),
                  child: Text(tr.apply),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
