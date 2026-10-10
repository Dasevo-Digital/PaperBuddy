/// Barcodes beim Verarbeiten, wie in Paperless-ngx
/// (`CONSUMER_ENABLE_BARCODES`, `CONSUMER_ENABLE_ASN_BARCODE`).
class BarcodeSettings {
  const BarcodeSettings({
    this.split = false,
    this.separator = 'PATCHT',
    this.asn = false,
    this.asnPrefix = 'ASN',
    this.dpi = 300,
    this.maxPages = 0,
  });

  /// An Trennblättern mit [separator] aufteilen; Seiten mit ASN-Barcode
  /// beginnen dann ebenfalls ein neues Dokument.
  final bool split;
  final String separator;

  /// Archivnummer aus Barcodes mit [asnPrefix] übernehmen (`ASN00042` → 42).
  final bool asn;
  final String asnPrefix;

  /// Auflösung beim Rendern der Seiten.
  final int dpi;

  /// Nur die ersten Seiten durchsuchen; 0 = alle.
  final int maxPages;

  bool get enabled => split || asn;
}

/// Ein Teil eines Stapelscans: Seiten [first] bis [last] (ab 1, einschließlich).
class BarcodePart {
  const BarcodePart(this.first, this.last, [this.asn]);
  final int first;
  final int last;
  final int? asn;

  @override
  String toString() => '$first-$last${asn == null ? '' : ' (ASN $asn)'}';

  @override
  bool operator ==(Object other) => other is BarcodePart && other.first == first && other.last == last && other.asn == asn;

  @override
  int get hashCode => Object.hash(first, last, asn);
}

/// ASN aus einem Barcode wie `ASN00042` oder `ASN 42`; `null`, wenn keiner.
int? asnFromCode(String code, String prefix) {
  if (!code.toUpperCase().startsWith(prefix.toUpperCase())) return null;
  final digits = code.substring(prefix.length).replaceAll(RegExp(r'[\s_-]'), '');
  return RegExp(r'^\d{1,9}$').hasMatch(digits) ? int.parse(digits) : null;
}

/// Teilt einen Scan mit [pages] Seiten anhand der Barcodes je Seite
/// ([codes], ggf. nur die ersten Seiten). Trennblätter fallen weg; mit
/// [BarcodeSettings.split] beginnt auch jede Seite mit ASN-Barcode ein neues
/// Dokument, sonst gilt die erste gefundene ASN für das ganze.
List<BarcodePart> planBarcodeSplit(List<List<String>> codes, int pages, BarcodeSettings s) {
  final parts = <BarcodePart>[];
  int? start;
  int? asn;
  void close(int last) {
    if (start != null && last >= start!) parts.add(BarcodePart(start!, last, asn));
    start = null;
    asn = null;
  }

  for (var page = 1; page <= pages; page++) {
    final found = page <= codes.length ? codes[page - 1] : const <String>[];
    if (s.split && found.contains(s.separator)) {
      close(page - 1);
      continue;
    }
    final pageAsn = s.asn ? found.map((c) => asnFromCode(c, s.asnPrefix)).whereType<int>().firstOrNull : null;
    if (pageAsn != null && s.split && start != null && page > start!) close(page - 1);
    start ??= page;
    if (pageAsn != null) asn ??= pageAsn;
  }
  close(pages);
  return parts;
}
