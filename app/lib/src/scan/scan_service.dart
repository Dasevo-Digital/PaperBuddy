import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Dokumentenscanner mit Kantenerkennung (iOS VisionKit, Android ML Kit).
abstract final class ScanService {
  static bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Öffnet den Scanner. Liefert die Seiten als JPEG/PNG oder `null` bei Abbruch.
  static Future<List<Uint8List>?> scanPages({bool allowGallery = true}) async {
    final paths = await CunningDocumentScanner.getPictures(
      scannerSource: allowGallery
          ? ScannerSource.cameraAndGallery
          : ScannerSource.camera,
      iosScannerOptions: IosScannerOptions(
        imageFormat: IosImageFormat.jpg,
        jpgCompressionQuality: 0.8,
      ),
    );
    if (paths == null || paths.isEmpty) return null;
    final pages = [for (final p in paths) await File(p).readAsBytes()];
    try {
      await CunningDocumentScanner.cleanCache();
    } catch (_) {
      // Aufräumen ist nicht kritisch; der Cache wird beim nächsten Mal geleert.
    }
    return pages;
  }
}

/// Fügt Seitenbilder zu einem PDF zusammen, eine Seite pro Bild.
///
/// Die Seitengröße folgt dem Seitenverhältnis des Bildes bei A4-Breite,
/// damit nichts beschnitten oder verzerrt wird. Läuft in einem Isolate.
Future<Uint8List> buildPdfFromImages(List<Uint8List> pages) =>
    compute(_buildPdf, pages);

Future<Uint8List> _buildPdf(List<Uint8List> pages) async {
  final doc = pw.Document(title: 'Scan', creator: 'PaperBuddy');
  for (final bytes in pages) {
    final image = pw.MemoryImage(bytes);
    final w = (image.width ?? 2480).toDouble();
    final h = (image.height ?? 3508).toDouble();
    final format = PdfPageFormat(
      PdfPageFormat.a4.width,
      PdfPageFormat.a4.width * h / w,
    );
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, fit: pw.BoxFit.contain),
      ),
    );
  }
  return doc.save();
}
