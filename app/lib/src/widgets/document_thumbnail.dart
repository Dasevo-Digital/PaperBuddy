import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../file_kinds.dart';

class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.documentId,
    this.mimeType,
    this.fit = BoxFit.cover,
  });

  final int documentId;

  /// Für das Symbol, solange es kein Vorschaubild gibt.
  final String? mimeType;
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
            // Nur so groß dekodieren wie angezeigt (die Vorschau ist 500 px
            // breit, in der Liste aber nur wenige Dutzend Punkte).
            return LayoutBuilder(
              builder: (context, constraints) {
                final dpr = MediaQuery.devicePixelRatioOf(context);
                final w = constraints.maxWidth;
                return Image.memory(
                  bytes,
                  fit: widget.fit,
                  alignment: Alignment.topCenter,
                  gaplessPlayback: true,
                  cacheWidth: w.isFinite && w > 0 ? (w * dpr).ceil() : null,
                  errorBuilder: (_, _, _) => _placeholder(scheme),
                );
              },
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

  Widget _placeholder(ColorScheme scheme) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(FileKinds.icon(widget.mimeType), color: scheme.onSurfaceVariant),
        if (widget.mimeType != null)
          Text(
            FileKinds.label(widget.mimeType!),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );
}
