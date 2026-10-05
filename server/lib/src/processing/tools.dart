import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('tools');

/// Externe Programme für OCR und Vorschau. Fehlt eines, läuft die
/// Verarbeitung mit eingeschränktem Funktionsumfang weiter.
class ExternalTools {
  ExternalTools({required this.ocrLanguage});
  final String ocrLanguage;

  final _available = <String, bool>{};

  Future<bool> has(String tool) async => _available[tool] ??= await () async {
    try {
      final r = await Process.run('which', [tool]);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  Future<Map<String, bool>> report() async => {
    for (final t in [
      'ocrmypdf',
      'tesseract',
      'pdftotext',
      'pdftoppm',
      'pdfinfo',
      'qpdf',
      'soffice',
    ])
      t: await has(t),
  };

  Future<ProcessResult?> _run(String tool, List<String> args) async {
    if (!await has(tool)) return null;
    final r = await Process.run(tool, args);
    if (r.exitCode != 0) {
      _log.warning('$tool fehlgeschlagen (${r.exitCode}): ${r.stderr}');
    }
    return r;
  }

  /// Erzeugt ein durchsuchbares PDF/A. Liefert `false`, wenn ocrmypdf fehlt
  /// oder scheitert.
  Future<bool> ocrPdf(
    String input,
    String output, {
    bool isImage = false,
  }) async {
    final r = await _run('ocrmypdf', [
      '--skip-text',
      '--rotate-pages',
      '--deskew',
      '--output-type',
      'pdfa',
      '-l',
      ocrLanguage,
      if (isImage) ...['--image-dpi', '300'],
      input,
      output,
    ]);
    return r != null && r.exitCode == 0 && await File(output).exists();
  }

  /// Durchsuchbares PDF direkt über Tesseract. Ausweichweg für Bilder, die
  /// ocrmypdf ablehnt (z. B. PNGs mit Alphakanal).
  Future<bool> imageToPdf(String image, String outputPdf) async {
    final base = outputPdf.replaceAll(RegExp(r'\.pdf$'), '');
    final r = await _run('tesseract', [image, base, '-l', ocrLanguage, 'pdf']);
    return r != null && r.exitCode == 0 && await File(outputPdf).exists();
  }

  /// Office-Datei per LibreOffice in ein PDF umwandeln (für Archiv-PDF,
  /// Vorschaubild und alte Binärformate). Liefert den Pfad oder `null`.
  Future<String?> officeToPdf(String input, String outputDir) async {
    if (!await has('soffice')) return null;
    final profile = Uri.directory('$outputDir/lo-profile').toString();
    final r = await Process.run('soffice', [
      '-env:UserInstallation=$profile',
      '--headless',
      '--norestore',
      '--convert-to',
      'pdf',
      '--outdir',
      outputDir,
      input,
    ]).timeout(const Duration(minutes: 3));
    final pdf = '$outputDir/${input.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '')}.pdf';
    if (r.exitCode != 0 || !await File(pdf).exists()) {
      _log.warning('soffice fehlgeschlagen (${r.exitCode}): ${r.stderr}');
      return null;
    }
    return pdf;
  }

  /// qpdf mit Argumenten; wirft bei Fehler oder fehlendem Programm.
  Future<void> qpdf(List<String> args) async {
    if (!await has('qpdf')) throw StateError('qpdf ist nicht installiert (für PDF-Bearbeitung nötig).');
    final r = await Process.run('qpdf', args);
    // Exit-Code 3 = Warnungen, Ergebnis ist trotzdem gültig.
    if (r.exitCode != 0 && r.exitCode != 3) throw StateError('qpdf: ${r.stderr}');
  }

  Future<String?> pdfText(String pdf) async {
    final r = await _run('pdftotext', ['-enc', 'UTF-8', pdf, '-']);
    return r != null && r.exitCode == 0 ? r.stdout as String : null;
  }

  Future<String?> imageText(String image) async {
    final r = await _run('tesseract', [
      image,
      'stdout',
      '-l',
      ocrLanguage.replaceAll(',', '+'),
    ]);
    return r != null && r.exitCode == 0 ? r.stdout as String : null;
  }

  Future<int?> pdfPageCount(String pdf) async {
    final r = await _run('pdfinfo', [pdf]);
    if (r == null || r.exitCode != 0) return null;
    final m = RegExp(
      r'^Pages:\s+(\d+)',
      multiLine: true,
    ).firstMatch(r.stdout as String);
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// Vorschaubild der ersten Seite als PNG.
  Future<bool> pdfThumbnail(String pdf, String outputPng) async {
    final prefix = outputPng.replaceAll(RegExp(r'\.png$'), '');
    final r = await _run('pdftoppm', [
      '-png',
      '-singlefile',
      '-scale-to',
      '500',
      '-f',
      '1',
      '-l',
      '1',
      pdf,
      prefix,
    ]);
    return r != null && r.exitCode == 0 && await File(outputPng).exists();
  }
}
