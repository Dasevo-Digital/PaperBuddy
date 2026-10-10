import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'l10n.dart';

/// Dateitypen, die der Server verarbeitet: Endungen für die Dateiauswahl,
/// kurze Bezeichnungen und Symbole. Den Typ selbst bestimmt der Server am
/// Inhalt; die Endung dient nur der Auswahl im Dateidialog.
abstract final class FileKinds {
  static const uploadExtensions = [
    'pdf',
    'png',
    'jpg',
    'jpeg',
    'tif',
    'tiff',
    'webp',
    'txt',
    'csv',
    // E-Rechnung (XRechnung)
    'xml',
    'docx',
    'xlsx',
    'pptx',
    'odt',
    'ods',
    'odp',
    'doc',
    'xls',
    'ppt',
  ];

  static Map<String, String> get _labels => {
    'application/pdf': 'PDF',
    'text/plain': 'TXT',
    'text/csv': 'CSV',
    'image/jpeg': 'JPG',
    'image/png': 'PNG',
    'image/tiff': 'TIFF',
    'image/webp': 'WEBP',
    'image/heic': 'HEIC',
    'message/rfc822': tr.email,
    'text/html': 'HTML',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'XLSX',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        'DOCX',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation':
        'PPTX',
    'application/vnd.oasis.opendocument.text': 'ODT',
    'application/vnd.oasis.opendocument.spreadsheet': 'ODS',
    'application/vnd.oasis.opendocument.presentation': 'ODP',
    'application/msword': 'DOC',
    'application/vnd.ms-excel': 'XLS',
    'application/vnd.ms-powerpoint': 'PPT',
  };

  /// Kurzform wie „PDF“ oder „DOCX“.
  static String label(String mimeType) =>
      _labels[mimeType] ?? mimeType.split('/').last.toUpperCase();

  /// Ausgeschrieben für die Detailansicht, z. B. „Word-Dokument (DOCX)“.
  static String describe(String mimeType) {
    final short = label(mimeType);
    final kind = switch (short) {
      'PDF' => tr.pdfDocument,
      'TXT' => tr.textFile,
      'CSV' => tr.csvSpreadsheet,
      'JPG' || 'PNG' || 'TIFF' || 'WEBP' || 'HEIC' => tr.image,
      'DOCX' || 'DOC' || 'ODT' => tr.textDocument,
      'XLSX' || 'XLS' || 'ODS' => tr.spreadsheet,
      'PPTX' || 'PPT' || 'ODP' => tr.presentation,
      'XML' => tr.eInvoice,
      _ => null,
    };
    return kind == null ? short : '$kind ($short)';
  }

  static IconData icon(String? mimeType) {
    final m = mimeType ?? '';
    if (m.startsWith('image/')) return LucideIcons.fileImage;
    if (m == 'text/csv' || m.contains('spreadsheet') || m.contains('excel')) {
      return LucideIcons.fileSpreadsheet;
    }
    if (m.contains('presentation') || m.contains('powerpoint')) {
      return LucideIcons.presentation;
    }
    if (m.startsWith('text/')) return LucideIcons.fileType;
    return LucideIcons.fileText;
  }
}
