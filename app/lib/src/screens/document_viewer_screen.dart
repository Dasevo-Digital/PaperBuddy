import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_state.dart';
import '../file_export.dart';

/// Vollbildansicht: Archiv-PDF bzw. Original (Bild, Text).
class DocumentViewerScreen extends StatefulWidget {
  const DocumentViewerScreen({
    super.key,
    required this.document,
    this.original = false,
  });

  final Document document;
  final bool original;

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late Future<DownloadedFile> _file;
  late bool _original = widget.original;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _file = AppScope.read(
      context,
    ).client.downloadFile(widget.document.id, original: _original);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.document.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.document.hasArchiveVersion)
            IconButton(
              tooltip: _original ? 'Archiv-PDF anzeigen' : 'Original anzeigen',
              icon: Icon(
                _original ? LucideIcons.fileCheck : LucideIcons.fileImage,
              ),
              onPressed: () => setState(() {
                _original = !_original;
                _load();
              }),
            ),
          FutureBuilder<DownloadedFile>(
            future: _file,
            builder: (context, snap) => IconButton(
              tooltip: 'Teilen oder speichern',
              icon: const Icon(LucideIcons.share),
              onPressed: snap.data == null
                  ? null
                  : () => exportFile(
                      context,
                      Uint8List.fromList(snap.data!.bytes),
                      snap.data!.fileName,
                      snap.data!.mimeType,
                    ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<DownloadedFile>(
        future: _file,
        builder: (context, snap) {
          if (snap.hasError) {
            final message = snap.error is ApiException
                ? (snap.error as ApiException).message
                : '${snap.error}';
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.fileX, size: 48),
                  const SizedBox(height: 12),
                  Text(message),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () => setState(_load),
                    child: const Text('Erneut versuchen'),
                  ),
                ],
              ),
            );
          }
          final file = snap.data;
          if (file == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final bytes = Uint8List.fromList(file.bytes);
          if (file.isPdf) {
            return PdfViewer.data(
              bytes,
              sourceName: '${widget.document.id}-${_original ? 'o' : 'a'}.pdf',
              params: const PdfViewerParams(
                margin: 8,
                backgroundColor: Colors.transparent,
              ),
            );
          }
          if (file.isImage) {
            return InteractiveViewer(
              maxScale: 8,
              child: Center(child: Image.memory(bytes)),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              utf8.decode(file.bytes, allowMalformed: true),
            ),
          );
        },
      ),
    );
  }
}
