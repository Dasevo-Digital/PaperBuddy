import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_state.dart';

class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.documentId,
    this.fit = BoxFit.cover,
  });

  final int documentId;
  final BoxFit fit;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  @override
  void didUpdateWidget(DocumentThumbnail old) {
    super.didUpdateWidget(old);
    if (old.documentId != widget.documentId) _future = _load();
  }

  Future<Uint8List?> _load() {
    final state = AppScope.read(context);
    return state.thumbnails.get(state.client, widget.documentId);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null) {
            return Image.memory(
              bytes,
              fit: widget.fit,
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _placeholder(scheme),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox.expand();
          }
          return _placeholder(scheme);
        },
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) =>
      Center(child: Icon(LucideIcons.fileText, color: scheme.onSurfaceVariant));
}
