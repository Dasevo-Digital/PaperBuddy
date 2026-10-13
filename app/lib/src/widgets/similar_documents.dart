import 'package:flutter/material.dart';
import 'package:paperbuddy_api/paperbuddy_api.dart';

import '../app_state.dart';
import '../l10n.dart';
import '../screens/document_screen.dart';
import 'document_tiles.dart';

/// Die ähnlichsten Dokumente (`more_like_id`); mit lokaler KI auf dem
/// Server nach Bedeutung, sonst nach gemeinsamen Wörtern. Lädt erst beim
/// Aufklappen.
class SimilarDocumentsSection extends StatefulWidget {
  const SimilarDocumentsSection({super.key, required this.documentId});

  final int documentId;

  @override
  State<SimilarDocumentsSection> createState() => _SimilarDocumentsSectionState();
}

class _SimilarDocumentsSectionState extends State<SimilarDocumentsSection> {
  Future<List<Document>>? _documents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr.similarDocuments, style: theme.textTheme.titleMedium),
      onExpansionChanged: (open) {
        if (open && _documents == null) {
          final documents = AppScope.read(context).client.similarDocuments(widget.documentId);
          setState(() {
            _documents = documents;
          });
        }
      },
      children: [
        FutureBuilder<List<Document>>(
          future: _documents,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}');
            final documents = snap.data;
            if (documents == null) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              );
            }
            if (documents.isEmpty) return Text(tr.noSimilarDocuments);
            return Column(
              children: [
                for (final d in documents)
                  DocumentListTile(
                    document: d,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => DocumentScreen(document: d)),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
