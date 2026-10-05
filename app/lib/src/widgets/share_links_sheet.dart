import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../format.dart';
import 'dialogs.dart';

/// Freigabelinks eines Dokuments: anlegen, kopieren, löschen.
Future<void> showShareLinksSheet(BuildContext context, Document document) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ShareLinksSheet(document: document),
    );

class _ShareLinksSheet extends StatefulWidget {
  const _ShareLinksSheet({required this.document});
  final Document document;

  @override
  State<_ShareLinksSheet> createState() => _ShareLinksSheetState();
}

class _ShareLinksSheetState extends State<_ShareLinksSheet> {
  late Future<List<ShareLink>> _links;
  int? _days = 7;
  bool _original = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() =>
      _links = AppScope.read(context).client.shareLinks(widget.document.id);

  Future<void> _copy(ShareLink link) async {
    final url = AppScope.read(context).client.shareLinkUrl(link).toString();
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showInfo(context, 'Link kopiert');
  }

  Future<void> _create() async {
    final client = AppScope.read(context).client;
    final link = await guarded(
      context,
      () => client.createShareLink(
        widget.document.id,
        expiration: _days == null
            ? null
            : DateTime.now().add(Duration(days: _days!)),
        original: _original,
      ),
    );
    if (link == null || !mounted) return;
    await _copy(link);
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = AppScope.of(context).client.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Freigabelinks', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Wer den Link kennt, kann das Dokument ohne Anmeldung öffnen.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<ShareLink>>(
            future: _links,
            builder: (context, snap) {
              if (snap.hasError) {
                return Text(
                  '${snap.error}',
                  style: TextStyle(color: theme.colorScheme.error),
                );
              }
              final links = snap.data;
              if (links == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return Column(
                children: [
                  for (final l in links)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(LucideIcons.link),
                      title: Text(
                        l.fileVersion == 'original' ? 'Original' : 'Archiv-PDF',
                      ),
                      subtitle: Text(
                        l.expiration == null
                            ? 'Unbegrenzt gültig'
                            : 'Gültig bis ${formatDayTime(l.expiration!)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Kopieren',
                            icon: const Icon(LucideIcons.copy),
                            onPressed: () => _copy(l),
                          ),
                          if (user.can('delete', 'sharelink'))
                            IconButton(
                              tooltip: 'Löschen',
                              icon: const Icon(LucideIcons.trash2),
                              onPressed: () async {
                                await guarded(
                                  context,
                                  () => AppScope.read(
                                    context,
                                  ).client.deleteShareLink(l.id),
                                );
                                if (mounted) setState(_reload);
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          if (user.can('add', 'sharelink')) ...[
            const Divider(),
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    initialValue: _days,
                    decoration: const InputDecoration(labelText: 'Gültig'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 Tag')),
                      DropdownMenuItem(value: 7, child: Text('7 Tage')),
                      DropdownMenuItem(value: 30, child: Text('30 Tage')),
                      DropdownMenuItem(value: null, child: Text('Unbegrenzt')),
                    ],
                    onChanged: (v) => setState(() => _days = v),
                  ),
                ),
                Expanded(
                  child: DropdownButtonFormField<bool>(
                    initialValue: _original,
                    decoration: const InputDecoration(labelText: 'Datei'),
                    items: const [
                      DropdownMenuItem(value: false, child: Text('Archiv-PDF')),
                      DropdownMenuItem(value: true, child: Text('Original')),
                    ],
                    onChanged: (v) => setState(() => _original = v ?? false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(LucideIcons.link),
              label: const Text('Link erstellen und kopieren'),
            ),
          ],
        ],
      ),
    );
  }
}
