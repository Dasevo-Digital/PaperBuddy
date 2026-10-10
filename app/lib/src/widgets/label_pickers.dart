import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../format.dart';
import 'tag_chip.dart';
import '../l10n.dart';

/// Auswahl eines Eintrags (Korrespondent, Dokumenttyp, Speicherpfad) mit
/// Suche und optionalem Neuanlegen.
///
/// Liefert die gewählte ID, `-1` für „keiner“ oder `null` bei Abbruch.
Future<int?> pickLabel<T extends Label>(
  BuildContext context, {
  required String title,
  required List<T> options,
  int? selected,
  Future<T> Function(String name)? onCreate,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _LabelPicker<T>(
      title: title,
      options: options,
      selected: selected == null ? {} : {selected},
      multi: false,
      onCreate: onCreate,
    ),
  ).then((v) => v);
}

/// Mehrfachauswahl von Tags. Liefert die neue Menge oder `null` bei Abbruch.
Future<Set<int>?> pickTags(
  BuildContext context, {
  required List<Tag> options,
  required Set<int> selected,
  Future<Tag> Function(String name)? onCreate,
}) {
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _LabelPicker<Tag>(
      title: 'Tags',
      options: options,
      selected: selected,
      multi: true,
      onCreate: onCreate,
    ),
  );
}

class _LabelPicker<T extends Label> extends StatefulWidget {
  const _LabelPicker({
    required this.title,
    required this.options,
    required this.selected,
    required this.multi,
    this.onCreate,
  });

  final String title;
  final List<T> options;
  final Set<int> selected;
  final bool multi;
  final Future<T> Function(String name)? onCreate;

  @override
  State<_LabelPicker<T>> createState() => _LabelPickerState<T>();
}

class _LabelPickerState<T extends Label> extends State<_LabelPicker<T>> {
  final _search = TextEditingController();
  late final Set<int> _selected = {...widget.selected};
  late final List<T> _options = [...widget.options];
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _search.text.trim();
    if (name.isEmpty || widget.onCreate == null) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final created = await widget.onCreate!(name);
      if (!mounted) return;
      if (widget.multi) {
        setState(() {
          _options.add(created);
          _selected.add(created.id);
          _search.clear();
        });
      } else {
        Navigator.pop(context, created.id);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final filtered =
        _options.where((o) => o.name.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            // Ausgewählte zuerst, dann alphabetisch.
            final sa = _selected.contains(a.id) ? 0 : 1;
            final sb = _selected.contains(b.id) ? 0 : 1;
            return sa != sb
                ? sa - sb
                : a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    final exact = _options.any((o) => o.name.toLowerCase() == query);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleLarge),
                ),
                if (!widget.multi && widget.selected.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.pop(context, -1),
                    child: Text(tr.remove),
                  ),
                if (widget.multi)
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: Text(tr.applyPicker),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _search,
              autofocus: _options.length > 8,
              decoration: InputDecoration(
                hintText: widget.onCreate == null
                    ? tr.search
                    : tr.searchOrCreate,
                prefixIcon: const Icon(LucideIcons.search),
                errorText: _error,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (!exact && query.isNotEmpty) _create();
              },
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                if (widget.onCreate != null && query.isNotEmpty && !exact)
                  ListTile(
                    leading: _creating
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.plus),
                    title: Text(tr.createNamed(_search.text.trim())),
                    onTap: _creating ? null : _create,
                  ),
                for (final o in filtered)
                  widget.multi
                      ? CheckboxListTile(
                          value: _selected.contains(o.id),
                          title: o is Tag
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: TagChip(tag: o, dense: false),
                                )
                              : Text(o.name),
                          secondary: Text(
                            '${o.documentCount}',
                            style: theme.textTheme.labelSmall,
                          ),
                          onChanged: (v) => setState(
                            () => v == true
                                ? _selected.add(o.id)
                                : _selected.remove(o.id),
                          ),
                        )
                      : ListTile(
                          leading: Icon(
                            _selected.contains(o.id)
                                ? LucideIcons.circleCheck
                                : LucideIcons.circle,
                          ),
                          title: Text(o.name),
                          subtitle: o is StoragePath ? Text(o.path) : null,
                          trailing: Text(
                            '${o.documentCount}',
                            style: theme.textTheme.labelSmall,
                          ),
                          onTap: () => Navigator.pop(context, o.id),
                        ),
                if (filtered.isEmpty &&
                    (widget.onCreate == null || query.isEmpty))
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr.noEntries,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Farbe für neu angelegte Tags, reihum aus einer ruhigen Palette.
String nextTagColor(int existingCount) {
  const palette = [
    '#a6cee3',
    '#1f78b4',
    '#b2df8a',
    '#33a02c',
    '#fb9a99',
    '#e31a1c',
    '#fdbf6f',
    '#ff7f00',
    '#cab2d6',
    '#6a3d9a',
    '#b15928',
    '#8dd3c7',
  ];
  return palette[existingCount % palette.length];
}

/// Für Tests und Anzeige: Farbwert eines Tags.
Color tagColor(Tag t) => Color(parseHexColor(t.color));

/// Formularfeld, das beim Antippen [pickLabel] öffnet.
class LabelField<T extends Label> extends StatelessWidget {
  const LabelField({
    super.key,
    required this.label,
    required this.icon,
    required this.options,
    required this.value,
    required this.onChanged,
    this.onCreate,
  });

  final String label;
  final IconData icon;
  final Map<int, T> options;
  final int? value;
  final ValueChanged<int?> onChanged;
  final Future<T> Function(String name)? onCreate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final picked = await pickLabel<T>(
          context,
          title: label,
          options: options.values.toList(),
          selected: value,
          onCreate: onCreate,
        );
        if (picked != null) onChanged(picked == -1 ? null : picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
        child: Text(value == null ? '–' : (options[value]?.name ?? '#$value')),
      ),
    );
  }
}

/// Tag-Auswahl mit Chips zum Entfernen.
class TagsField extends StatelessWidget {
  const TagsField({
    super.key,
    required this.tags,
    required this.selected,
    required this.onChanged,
    this.onCreate,
  });

  final Map<int, Tag> tags;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final Future<Tag> Function(String name)? onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Tags', style: theme.textTheme.titleMedium)),
            TextButton.icon(
              icon: const Icon(LucideIcons.tags),
              label: Text(tr.select),
              onPressed: () async {
                final picked = await pickTags(
                  context,
                  options: tags.values.toList(),
                  selected: selected,
                  onCreate: onCreate,
                );
                if (picked != null) onChanged(picked);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (selected.isEmpty)
          Text(tr.noTags, style: theme.textTheme.bodyMedium)
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in selected)
                if (tags[id] case final tag?)
                  InputChip(
                    label: TagChip(tag: tag),
                    onDeleted: () => onChanged({...selected}..remove(id)),
                  ),
            ],
          ),
      ],
    );
  }
}
