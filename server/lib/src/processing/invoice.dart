import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

/// Eine Rechnungsposition.
class InvoiceLine {
  InvoiceLine({required this.name, this.quantity, this.unit, this.amount});
  final String name;
  final String? quantity;
  final String? unit;

  /// Nettobetrag der Position als Dezimalzahl mit Punkt.
  final String? amount;
}

/// Rechnungsdaten, aus einer E-Rechnung (ZUGFeRD/Factur-X, XRechnung) oder
/// aus dem erkannten Text.
class InvoiceData {
  InvoiceData({required this.source, this.syntax});

  /// `xml` (E-Rechnung, verlässlich) oder `text` (aus dem OCR-Text erraten).
  final String source;

  /// `CII`, `UBL` oder `ZUGFeRD 1` bei E-Rechnungen.
  final String? syntax;
  String? number;
  DateTime? issueDate;
  DateTime? dueDate;
  String? currency;

  /// Zahlbetrag als Dezimalzahl mit Punkt, z. B. `142.37`.
  String? total;
  String? iban;
  String? seller;
  String? buyer;
  bool creditNote = false;
  final lines = <InvoiceLine>[];

  bool get isEmpty => number == null && total == null && iban == null && dueDate == null;

  /// Betrag im Format der Custom Fields von Paperless-ngx (`EUR142.37`).
  String? get monetary => total == null ? null : '${currency ?? 'EUR'}$total';
}

// ---------------------------------------------------------------------------
// E-Rechnung (XML)

Iterable<XmlElement> _all(XmlNode node, String local) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

XmlElement? _first(XmlNode node, String local) => _all(node, local).firstOrNull;

XmlElement? _childEl(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local).firstOrNull;

/// Pfad aus lokalen Namen, jeweils der erste passende Nachfahre.
XmlElement? _path(XmlNode node, List<String> names) {
  XmlNode? current = node;
  for (final n in names) {
    current = current == null ? null : _first(current, n);
  }
  return current as XmlElement?;
}

String? _text(XmlElement? e) {
  final t = e?.innerText.trim();
  return t == null || t.isEmpty ? null : t;
}

DateTime? _cii(XmlElement? dateTime) {
  final s = _text(dateTime == null ? null : (_first(dateTime, 'DateTimeString') ?? dateTime));
  if (s == null) return null;
  final compact = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(s);
  if (compact != null) {
    return DateTime(int.parse(compact[1]!), int.parse(compact[2]!), int.parse(compact[3]!));
  }
  return DateTime.tryParse(s);
}

String? _decimal(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s.trim());
  return v?.toStringAsFixed(2);
}

/// Liest eine E-Rechnung: UN/CEFACT CII (ZUGFeRD 2, Factur-X, XRechnung),
/// ZUGFeRD 1 oder UBL (XRechnung). `null`, wenn es keine ist.
InvoiceData? parseInvoiceXml(String source) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(source);
  } on XmlException {
    return null;
  }
  final root = doc.rootElement;
  switch (root.name.local) {
    case 'CrossIndustryInvoice' || 'CrossIndustryDocument':
      return _parseCii(root);
    case 'Invoice' || 'CreditNote':
      return _parseUbl(root);
  }
  return null;
}

InvoiceData _parseCii(XmlElement root) {
  final v1 = root.name.local == 'CrossIndustryDocument';
  final d = InvoiceData(source: 'xml', syntax: v1 ? 'ZUGFeRD 1' : 'CII');
  final header = _first(root, v1 ? 'HeaderExchangedDocument' : 'ExchangedDocument');
  if (header != null) {
    d.number = _text(_childEl(header, 'ID'));
    d.issueDate = _cii(_childEl(header, 'IssueDateTime'));
    d.creditNote = _text(_childEl(header, 'TypeCode')) == '381';
  }
  d.currency = _text(_first(root, 'InvoiceCurrencyCode'));
  final sums = _first(root, v1 ? 'SpecifiedTradeSettlementMonetarySummation' : 'SpecifiedTradeSettlementHeaderMonetarySummation');
  if (sums != null) {
    d.total = _decimal(_text(_childEl(sums, 'DuePayableAmount')) ?? _text(_childEl(sums, 'GrandTotalAmount')));
  }
  d.dueDate = _cii(_path(root, ['SpecifiedTradePaymentTerms', 'DueDateDateTime']));
  d.iban = _text(_path(root, ['PayeePartyCreditorFinancialAccount', 'IBANID']))?.replaceAll(' ', '');
  d.seller = _text(_path(root, ['SellerTradeParty', 'Name']));
  d.buyer = _text(_path(root, ['BuyerTradeParty', 'Name']));
  for (final item in _all(root, 'IncludedSupplyChainTradeLineItem')) {
    final quantity = _first(item, 'BilledQuantity');
    d.lines.add(InvoiceLine(
      name: _text(_path(item, ['SpecifiedTradeProduct', 'Name'])) ?? '',
      quantity: _text(quantity),
      unit: quantity?.getAttribute('unitCode'),
      amount: _decimal(_text(_first(item, 'LineTotalAmount'))),
    ));
  }
  return d;
}

InvoiceData _parseUbl(XmlElement root) {
  final d = InvoiceData(source: 'xml', syntax: 'UBL')..creditNote = root.name.local == 'CreditNote';
  d.number = _text(_childEl(root, 'ID'));
  d.issueDate = DateTime.tryParse(_text(_childEl(root, 'IssueDate')) ?? '');
  d.dueDate = DateTime.tryParse(_text(_childEl(root, 'DueDate')) ?? _text(_path(root, ['PaymentMeans', 'PaymentDueDate'])) ?? '');
  d.currency = _text(_childEl(root, 'DocumentCurrencyCode'));
  final total = _childEl(root, 'LegalMonetaryTotal');
  if (total != null) d.total = _decimal(_text(_childEl(total, 'PayableAmount')) ?? _text(_childEl(total, 'TaxInclusiveAmount')));
  d.iban = _text(_path(root, ['PaymentMeans', 'PayeeFinancialAccount', 'ID']))?.replaceAll(' ', '');
  String? party(String role) {
    final p = _childEl(root, role);
    if (p == null) return null;
    return _text(_path(p, ['PartyName', 'Name'])) ?? _text(_path(p, ['PartyLegalEntity', 'RegistrationName']));
  }

  d.seller = party('AccountingSupplierParty');
  d.buyer = party('AccountingCustomerParty');
  for (final line in root.childElements.where((e) => e.name.local == 'InvoiceLine' || e.name.local == 'CreditNoteLine')) {
    final quantity = _childEl(line, 'InvoicedQuantity') ?? _childEl(line, 'CreditedQuantity');
    d.lines.add(InvoiceLine(
      name: _text(_path(line, ['Item', 'Name'])) ?? '',
      quantity: _text(quantity),
      unit: quantity?.getAttribute('unitCode'),
      amount: _decimal(_text(_childEl(line, 'LineExtensionAmount'))),
    ));
  }
  return d;
}

/// Sieht der Text nach einer E-Rechnung im XML-Format aus?
bool looksLikeInvoiceXml(String head) =>
    head.contains('CrossIndustryInvoice') ||
    head.contains('CrossIndustryDocument') ||
    head.contains('urn:oasis:names:specification:ubl:schema:xsd:Invoice-2') ||
    head.contains('urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2');

// ---------------------------------------------------------------------------
// Aus dem erkannten Text

/// Stichwörter für den Zahlbetrag mit Gewicht; das stärkste gewinnt.
const _amountLabels = <(String, int)>[
  ('zu zahlender betrag', 6),
  ('gesamtbetrag', 5),
  ('rechnungsbetrag', 5),
  ('endbetrag', 5),
  ('zahlbetrag', 5),
  ('zu zahlen', 5),
  ('amount due', 5),
  ('total due', 5),
  ('grand total', 5),
  ('gesamtsumme', 4),
  ('bruttobetrag', 4),
  ('summe brutto', 4),
  ('brutto', 3),
  ('total', 3),
  ('summe', 2),
  ('betrag', 1),
];

const _numberLabels = [
  'rechnungsnummer',
  'rechnungs-nr',
  'rechnungsnr',
  'rechnung nr',
  'rechnung-nr',
  'rg.-nr',
  'rg-nr',
  're.-nr',
  're-nr',
  'invoice number',
  'invoice no',
  'invoice #',
  'belegnummer',
  'beleg-nr',
];

const _issueLabels = ['rechnungsdatum', 'invoice date', 'datum der rechnung'];
const _dueLabels = ['fällig am', 'fällig bis', 'fälligkeit', 'zahlbar bis', 'zahlungsziel', 'spätestens am', 'due date', 'payable by'];

/// Betrag mit zwei Nachkommastellen; Tausender mit Punkt, Komma, Leerzeichen
/// oder Apostroph (1.234,56 · 1,234.56 · 1 234,56 · 1'234.56).
final _amount = RegExp(r"(?<![\d.,])(-?\d{1,3}(?:[.,  ']\d{3})+|-?\d+)([.,])(\d{2})(?![\d])");

/// Rät Rechnungsdaten aus dem OCR-Text. `null`, wenn der Text nicht nach
/// Rechnung aussieht oder weder Betrag noch Nummer zu finden sind.
InvoiceData? invoiceFromText(String text) {
  if (!RegExp(r'rechnung|invoice|faktura|gutschrift', caseSensitive: false).hasMatch(text)) return null;
  final lines = [for (final l in text.split('\n')) l.trim()];
  final lower = [for (final l in lines) l.toLowerCase()];
  final d = InvoiceData(source: 'text')..creditNote = RegExp(r'gutschrift|credit note', caseSensitive: false).hasMatch(text);

  // Zahlbetrag: stärkstes Stichwort, bei Gleichstand der größte Betrag.
  (int, double, String)? best;
  for (var i = 0; i < lines.length; i++) {
    final l = lower[i];
    if (l.contains('zwischensumme') || l.contains('subtotal') || (l.contains('netto') && !l.contains('brutto'))) continue;
    final weight = _amountLabels.where((x) => l.contains(x.$1)).map((x) => x.$2).fold(0, (a, b) => a > b ? a : b);
    if (weight == 0) continue;
    var matches = _amount.allMatches(lines[i]).toList();
    if (matches.isEmpty && i + 1 < lines.length) matches = _amount.allMatches(lines[i + 1]).toList();
    if (matches.isEmpty) continue;
    final m = matches.last;
    final value = double.parse('${m[1]!.replaceAll(RegExp(r"[.,  ']"), '')}.${m[3]}').abs();
    if (best == null || weight > best.$1 || (weight == best.$1 && value > best.$2)) {
      best = (weight, value, value.toStringAsFixed(2));
    }
  }
  d.total = best?.$3;
  if (d.total != null) {
    d.currency = RegExp(r'\bCHF\b').hasMatch(text)
        ? 'CHF'
        : RegExp(r'\bUSD\b|\$').hasMatch(text) && !text.contains('€') && !RegExp(r'\bEUR\b').hasMatch(text)
        ? 'USD'
        : 'EUR';
  }

  d.number = _afterLabel(lines, lower, _numberLabels, (s) {
    final m = RegExp(r'^[\s:.#-]*(?:nr\.?|no\.?)?[\s:.#-]*([A-Za-z0-9][A-Za-z0-9\-/_.]*[A-Za-z0-9])').firstMatch(s);
    final token = m?[1];
    return token != null && token.length >= 3 && RegExp(r'\d').hasMatch(token) ? token : null;
  });
  d.issueDate = _afterLabel(lines, lower, _issueLabels, _findDate);
  d.dueDate = _afterLabel(lines, lower, _dueLabels, _findDate);
  if (d.dueDate == null && d.issueDate != null) {
    final term = RegExp(r'(?:innerhalb|binnen|within)\s+(?:von\s+)?(\d{1,3})\s+(?:tagen|days)', caseSensitive: false)
        .firstMatch(text);
    if (term != null) d.dueDate = d.issueDate!.add(Duration(days: int.parse(term[1]!)));
  }
  d.iban = findIban(text);
  if (d.total == null && d.number == null) return null;
  return d;
}

/// Wert hinter einem der [labels] auf derselben oder der nächsten Zeile.
T? _afterLabel<T>(List<String> lines, List<String> lower, List<String> labels, T? Function(String rest) read) {
  for (var i = 0; i < lines.length; i++) {
    for (final label in labels) {
      final at = lower[i].indexOf(label);
      if (at < 0) continue;
      final value = read(lines[i].substring(at + label.length)) ?? (i + 1 < lines.length ? read(lines[i + 1]) : null);
      if (value != null) return value;
    }
  }
  return null;
}

const _months = {
  'januar': 1, 'jänner': 1, 'january': 1, 'jan': 1,
  'februar': 2, 'february': 2, 'feb': 2,
  'märz': 3, 'maerz': 3, 'march': 3, 'mär': 3, 'mar': 3,
  'april': 4, 'apr': 4,
  'mai': 5, 'may': 5,
  'juni': 6, 'june': 6, 'jun': 6,
  'juli': 7, 'july': 7, 'jul': 7,
  'august': 8, 'aug': 8,
  'september': 9, 'sep': 9, 'sept': 9,
  'oktober': 10, 'october': 10, 'okt': 10, 'oct': 10,
  'november': 11, 'nov': 11,
  'dezember': 12, 'december': 12, 'dez': 12, 'dec': 12,
};

/// Erstes Datum im Text: 15.09.2026, 15.9.26, 2026-09-15, 15. September 2026.
DateTime? _findDate(String s) {
  DateTime? valid(int y, int m, int d) {
    if (y < 100) y += 2000;
    if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1990 || y > 2100) return null;
    final date = DateTime(y, m, d);
    return date.month == m ? date : null;
  }

  final numeric = RegExp(r'\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b').firstMatch(s);
  final iso = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b').firstMatch(s);
  final named = RegExp(r'\b(\d{1,2})\.?\s+([A-Za-zÄÖÜäöü]{3,9})\.?\s+(\d{4})\b').firstMatch(s);
  // Englisch: March 16, 2026
  final monthFirst = RegExp(r'\b([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})\b').firstMatch(s);
  final found = <(int, DateTime)>[
    if (numeric != null)
      if (valid(int.parse(numeric[3]!), int.parse(numeric[2]!), int.parse(numeric[1]!)) case final d?) (numeric.start, d),
    if (iso != null)
      if (valid(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!)) case final d?) (iso.start, d),
    if (named != null && _months[named[2]!.toLowerCase()] != null)
      if (valid(int.parse(named[3]!), _months[named[2]!.toLowerCase()]!, int.parse(named[1]!)) case final d?) (named.start, d),
    if (monthFirst != null && _months[monthFirst[1]!.toLowerCase()] != null)
      if (valid(int.parse(monthFirst[3]!), _months[monthFirst[1]!.toLowerCase()]!, int.parse(monthFirst[2]!)) case final d?)
        (monthFirst.start, d),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return found.firstOrNull?.$2;
}

/// Länge der IBAN je Land (die gängigen in Europa).
const _ibanLengths = {
  'AT': 20, 'BE': 16, 'CH': 21, 'CZ': 24, 'DE': 22, 'DK': 18, 'ES': 24, 'FI': 18, 'FR': 27, 'GB': 22,
  'IE': 22, 'IT': 27, 'LI': 21, 'LU': 20, 'NL': 18, 'NO': 15, 'PL': 28, 'PT': 25, 'SE': 24,
};

/// Prüfsumme nach ISO 13616 (Modulo 97).
bool isValidIban(String iban) {
  final s = iban.replaceAll(' ', '').toUpperCase();
  final length = _ibanLengths[s.length >= 2 ? s.substring(0, 2) : ''];
  if (length == null || s.length != length || !RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(s)) return false;
  final rearranged = '${s.substring(4)}${s.substring(0, 4)}';
  var rest = 0;
  for (final c in rearranged.codeUnits) {
    final digits = c >= 65 ? '${c - 55}' : String.fromCharCode(c);
    for (final ch in digits.codeUnits) {
      rest = (rest * 10 + ch - 48) % 97;
    }
  }
  return rest == 1;
}

/// Erste gültige IBAN im Text, bevorzugt hinter „IBAN“.
String? findIban(String text) {
  final candidates = <(bool, String)>[];
  for (final m in RegExp(r'\b([A-Z]{2}\d{2}(?:\s?[A-Z0-9]){10,30})').allMatches(text)) {
    final compact = m[1]!.replaceAll(' ', '');
    final length = _ibanLengths[compact.substring(0, 2)];
    if (length == null || compact.length < length) continue;
    final iban = compact.substring(0, length);
    if (!isValidIban(iban)) continue;
    final before = text.substring((m.start - 12).clamp(0, m.start), m.start).toUpperCase();
    candidates.add((before.contains('IBAN'), iban));
  }
  return (candidates.where((c) => c.$1).firstOrNull ?? candidates.firstOrNull)?.$2;
}

// ---------------------------------------------------------------------------
// Darstellung einer XML-Rechnung

String _day(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _money(String amount, String? currency) {
  final parts = amount.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '$whole,${parts.length > 1 ? parts[1] : '00'} ${currency ?? 'EUR'}';
}

/// Durchsuchbarer Text einer E-Rechnung (deutsch und englisch beschriftet).
String invoiceSummary(InvoiceData d) {
  final out = StringBuffer()
    ..writeln('${d.creditNote ? 'Gutschrift / Credit note' : 'Rechnung / Invoice'} ${d.number ?? ''}'.trim());
  void line(String label, String? value) {
    if (value != null && value.isNotEmpty) out.writeln('$label: $value');
  }

  line('Verkäufer / Seller', d.seller);
  line('Käufer / Buyer', d.buyer);
  line('Rechnungsdatum / Invoice date', d.issueDate == null ? null : _day(d.issueDate!));
  line('Fällig am / Due date', d.dueDate == null ? null : _day(d.dueDate!));
  if (d.lines.isNotEmpty) {
    out.writeln('Positionen / Items:');
    for (final l in d.lines) {
      final qty = l.quantity == null ? '' : '${l.quantity}${l.unit == null ? '' : ' ${l.unit}'} × ';
      out.writeln('  $qty${l.name}${l.amount == null ? '' : ': ${_money(l.amount!, d.currency)}'}');
    }
  }
  line('Gesamtbetrag / Total', d.total == null ? null : _money(d.total!, d.currency));
  line('IBAN', d.iban);
  if (d.syntax != null) line('Format', 'E-Rechnung (${d.syntax})');
  return out.toString().trim();
}

/// Lesbare Fassung einer reinen XML-Rechnung als PDF (Archiv und Vorschau).
Future<Uint8List> invoicePdf(InvoiceData d) {
  final doc = pw.Document(title: d.number, creator: 'PaperBuddy');
  pw.Widget field(String label, String? value) => value == null || value.isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Row(children: [
            pw.SizedBox(width: 150, child: pw.Text(label, style: const pw.TextStyle(color: PdfColors.grey700))),
            pw.Expanded(child: pw.Text(value)),
          ]),
        );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      build: (_) => [
        pw.Text(
          '${d.creditNote ? 'Gutschrift' : 'Rechnung'} ${d.number ?? ''}'.trim(),
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text('E-Rechnung (${d.syntax ?? 'XML'})', style: const pw.TextStyle(color: PdfColors.grey600)),
        pw.SizedBox(height: 20),
        field('Verkäufer', d.seller),
        field('Käufer', d.buyer),
        field('Rechnungsdatum', d.issueDate == null ? null : _day(d.issueDate!)),
        field('Fällig am', d.dueDate == null ? null : _day(d.dueDate!)),
        field('IBAN', d.iban),
        pw.SizedBox(height: 16),
        if (d.lines.isNotEmpty)
          pw.TableHelper.fromTextArray(
            headers: ['Position', 'Menge', 'Betrag'],
            data: [
              for (final l in d.lines)
                [
                  l.name,
                  l.quantity == null ? '' : '${l.quantity}${l.unit == null ? '' : ' ${l.unit}'}',
                  l.amount == null ? '' : _money(l.amount!, d.currency),
                ],
            ],
            cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight},
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
        pw.SizedBox(height: 16),
        if (d.total != null)
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Gesamtbetrag: ${_money(d.total!, d.currency)}',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
          ),
      ],
    ),
  );
  return doc.save();
}
