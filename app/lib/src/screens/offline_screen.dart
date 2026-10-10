import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';
import '../file_cache.dart';
import '../file_kinds.dart';
import '../format.dart';
import 'document_viewer_screen.dart';
import '../l10n.dart';

/// Offline gespeicherte Dokumente; funktioniert auch ohne Verbindung.
class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  Future<List<OfflineDocument>>? _docs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _docs ??= _load();
  }

  Future<List<OfflineDocument>> _load() async {
    final cache = await AppScope.read(context).offlineCache();
    final docs = (await cache?.offlineDocuments())?.values.toList() ?? [];
    docs.sort((a, b) => b.created.compareTo(a.created));
    return docs;
  }

  Future<void> _remove(OfflineDocument d) async {
    await AppScope.read(context).files?.removeOffline(d.id);
    if (!mounted) return;
    final docs = _load();
    setState(() {
      _docs = docs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.availableOffline)),
      body: FutureBuilder<List<OfflineDocument>>(
        future: _docs,
        builder: (context, snap) {
          final docs = snap.data;
          if (docs == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    Icon(
                      LucideIcons.cloudDownload,
                      size: 40,
                      color: scheme.onSurfaceVariant,
                    ),
                    Text(
                      tr.noDocumentsAvailableOfflineYet,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final d in docs)
                ListTile(
                  leading: Icon(FileKinds.icon(d.mimeType)),
                  title: Text(d.title),
                  subtitle: Text(
                    '${formatDay(d.created)} · ${FileKinds.label(d.mimeType)}',
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DocumentViewerScreen.offline(offline: d),
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: tr.removeFromDevice,
                    icon: const Icon(LucideIcons.x),
                    onPressed: () => _remove(d),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
