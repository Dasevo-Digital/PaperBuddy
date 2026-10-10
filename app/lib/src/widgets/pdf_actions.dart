import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import 'dialogs.dart';
import '../l10n.dart';

enum PdfAction { rotateLeft, rotateRight, rotate180, deletePages, split }

/// Menü „PDF bearbeiten“ für ein Dokument. [onDone] lädt das Dokument neu.
class PdfActionsMenu extends StatelessWidget {
  const PdfActionsMenu({
    super.key,
    required this.document,
    required this.onDone,
  });

  final Document document;
  final VoidCallback onDone;

  Future<void> _run(BuildContext context, PdfAction action) async {
    final state = AppScope.read(context);
    final client = state.client;
    final id = document.id;
    switch (action) {
      case PdfAction.rotateLeft || PdfAction.rotateRight || PdfAction.rotate180:
        final degrees = switch (action) {
          PdfAction.rotateLeft => 270,
          PdfAction.rotate180 => 180,
          _ => 90,
        };
        final ok = await guarded(
          context,
          () => client
              .bulkEdit([id], 'rotate', {'degrees': degrees})
              .then((_) => true),
        );
        if (ok == true && context.mounted) showInfo(context, tr.rotated);
      case PdfAction.deletePages:
        final text = await askText(
          context,
          title: tr.deletePages,
          label: tr.pages,
          hint: document.pageCount == null
              ? tr.pageRangeExample
              : tr.pageRangeHint(document.pageCount!),
        );
        if (text == null || !context.mounted) return;
        final pages = parsePages(text);
        if (pages.isEmpty) {
          return showError(context, tr.noValidPageNumbers);
        }
        final confirmed = await confirm(
          context,
          title: tr.deletePagesQuestion(pages.join(', ')),
          message: tr.thePagesWillBeRemoved,
          action: tr.delete,
          destructive: true,
        );
        if (!confirmed || !context.mounted) return;
        final ok = await guarded(
          context,
          () => client
              .bulkEdit([id], 'delete_pages', {'pages': pages})
              .then((_) => true),
        );
        if (ok == true && context.mounted) showInfo(context, tr.pagesDeleted);
      case PdfAction.split:
        final text = await askText(
          context,
          title: tr.splitDocument,
          label: tr.parts,
          hint: 'z. B. 1-2, 3, 4-6',
        );
        if (text == null || !context.mounted) return;
        final trashOriginal = await choose<bool>(
          context,
          title: tr.originalAfterwards,
          options: [(false, tr.keep), (true, tr.moveToTrash)],
        );
        if (trashOriginal == null) return;
        if (!context.mounted) return;
        final ok = await guarded(
          context,
          () => client
              .bulkEdit(
                [id],
                'split',
                {'pages': text, 'delete_originals': trashOriginal},
              )
              .then((_) => true),
        );
        if (ok == true && context.mounted) {
          showInfo(context, tr.partsAreBeingProcessed);
          state.notifyDocumentsChanged();
        }
    }
    onDone();
  }

  static List<int> parsePages(String text) => {
    for (final part in text.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty))
      ...switch (RegExp(r'^(\d+)-(\d+)$').firstMatch(part)) {
        final m? => [
          for (var n = int.parse(m.group(1)!); n <= int.parse(m.group(2)!); n++)
            n,
        ],
        _ => [?int.tryParse(part)],
      },
  }.toList()..sort();

  @override
  Widget build(BuildContext context) {
    final isPdf =
        document.mimeType == 'application/pdf' || document.hasArchiveVersion;
    if (!isPdf) return const SizedBox.shrink();
    return PopupMenuButton<PdfAction>(
      tooltip: tr.editPdf,
      icon: const Icon(LucideIcons.fileCog),
      onSelected: (a) => _run(context, a),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: PdfAction.rotateLeft,
          child: ListTile(
            leading: Icon(LucideIcons.rotateCcw),
            title: Text(tr.rotateLeft),
          ),
        ),
        PopupMenuItem(
          value: PdfAction.rotateRight,
          child: ListTile(
            leading: Icon(LucideIcons.rotateCw),
            title: Text(tr.rotateRight),
          ),
        ),
        PopupMenuItem(
          value: PdfAction.rotate180,
          child: ListTile(
            leading: Icon(LucideIcons.refreshCw),
            title: Text(tr.rotate180),
          ),
        ),
        PopupMenuItem(
          value: PdfAction.deletePages,
          child: ListTile(
            leading: Icon(LucideIcons.fileMinus),
            title: Text(tr.deletePages),
          ),
        ),
        PopupMenuItem(
          value: PdfAction.split,
          child: ListTile(
            leading: Icon(LucideIcons.scissors),
            title: Text(tr.split),
          ),
        ),
      ],
    );
  }
}
