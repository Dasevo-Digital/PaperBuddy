import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../../app_state.dart';
import '../../format.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/document_thumbnail.dart';

/// Gelöschte Dokumente wiederherstellen oder endgültig löschen.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<PageResult<Document>> _items;
  final _selected = <int>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _selected.clear();
    _items = AppScope.read(context).client.trash();
  }

  Future<void> _restore(List<int> ids) async {
    final state = AppScope.read(context);
    await guarded(context, () => state.client.restoreFromTrash(ids));
    state.notifyDocumentsChanged();
    state.refreshLabels().ignore();
    if (mounted) {
      showInfo(
        context,
        ids.length == 1
            ? 'Dokument wiederhergestellt'
            : '${ids.length} Dokumente wiederhergestellt',
      );
      setState(_reload);
    }
  }

  Future<void> _empty(List<int> ids, {required bool all}) async {
    final ok = await confirm(
      context,
      title: all ? 'Papierkorb leeren?' : 'Endgültig löschen?',
      message:
          'Dokumente und Dateien werden unwiderruflich vom Server gelöscht.',
      action: 'Endgültig löschen',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guarded(
      context,
      () => AppScope.read(context).client.emptyTrash(all ? const [] : ids),
    );
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selected.isEmpty ? 'Papierkorb' : '${_selected.length} ausgewählt',
        ),
        actions: [
          if (_selected.isNotEmpty) ...[
            IconButton(
              tooltip: 'Wiederherstellen',
              icon: const Icon(LucideIcons.undo2),
              onPressed: () => _restore(_selected.toList()),
            ),
            IconButton(
              tooltip: 'Endgültig löschen',
              icon: const Icon(LucideIcons.trash2),
              onPressed: () => _empty(_selected.toList(), all: false),
            ),
          ] else
            FutureBuilder<PageResult<Document>>(
              future: _items,
              builder: (context, snap) => TextButton(
                onPressed: (snap.data?.count ?? 0) == 0
                    ? null
                    : () => _empty(const [], all: true),
                child: const Text('Leeren'),
              ),
            ),
        ],
      ),
      body: FutureBuilder<PageResult<Document>>(
        future: _items,
        builder: (context, snap) {
          if (snap.hasError)
            return EmptyHint(icon: LucideIcons.cloudOff, text: '${snap.error}');
          final page = snap.data;
          if (page == null)
            return const Center(child: CircularProgressIndicator());
          if (page.results.isEmpty)
            return const EmptyHint(
              icon: LucideIcons.trash,
              text: 'Der Papierkorb ist leer.',
            );
          return RefreshIndicator(
            onRefresh: () async => setState(_reload),
            child: ListView.separated(
              itemCount: page.results.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == page.results.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Dokumente im Papierkorb werden nach der vom Server eingestellten Frist automatisch gelöscht.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                final d = page.results[i];
                final selected = _selected.contains(d.id);
                return ListTile(
                  selected: selected,
                  leading: SizedBox(
                    width: 40,
                    height: 52,
                    child: DocumentThumbnail(documentId: d.id),
                  ),
                  title: Text(d.title),
                  subtitle: Text(
                    'Gelöscht ${d.deletedAt == null ? '' : formatDayTime(d.deletedAt!)}',
                  ),
                  onTap: () => setState(
                    () =>
                        selected ? _selected.remove(d.id) : _selected.add(d.id),
                  ),
                  trailing: _selected.isEmpty
                      ? IconButton(
                          tooltip: 'Wiederherstellen',
                          icon: const Icon(LucideIcons.undo2),
                          onPressed: () => _restore([d.id]),
                        )
                      : Checkbox(
                          value: selected,
                          onChanged: (_) => setState(
                            () => selected
                                ? _selected.remove(d.id)
                                : _selected.add(d.id),
                          ),
                        ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
