import 'dart:convert';
import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:test/test.dart';

import 'helpers.dart';

/// Factur-X/ZUGFeRD 2 (UN/CEFACT CII), Profil EN 16931.
const cii = '''<?xml version="1.0" encoding="UTF-8"?>
<rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
  xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
  xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
  <rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>urn:cen.eu:en16931:2017</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>
  <rsm:ExchangedDocument>
    <ram:ID>RE-2026-0815</ram:ID><ram:TypeCode>380</ram:TypeCode>
    <ram:IssueDateTime><udt:DateTimeString format="102">20260915</udt:DateTimeString></ram:IssueDateTime>
  </rsm:ExchangedDocument>
  <rsm:SupplyChainTradeTransaction>
    <ram:IncludedSupplyChainTradeLineItem>
      <ram:SpecifiedTradeProduct><ram:Name>Strom Jahresabrechnung</ram:Name></ram:SpecifiedTradeProduct>
      <ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="KWH">2418</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>
      <ram:SpecifiedLineTradeSettlement><ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>119.64</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation></ram:SpecifiedLineTradeSettlement>
    </ram:IncludedSupplyChainTradeLineItem>
    <ram:ApplicableHeaderTradeAgreement>
      <ram:SellerTradeParty><ram:Name>Stadtwerke Musterstadt</ram:Name></ram:SellerTradeParty>
      <ram:BuyerTradeParty><ram:Name>Alex Beispiel</ram:Name></ram:BuyerTradeParty>
    </ram:ApplicableHeaderTradeAgreement>
    <ram:ApplicableHeaderTradeSettlement>
      <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
      <ram:SpecifiedTradeSettlementPaymentMeans><ram:TypeCode>58</ram:TypeCode>
        <ram:PayeePartyCreditorFinancialAccount><ram:IBANID>DE89370400440532013000</ram:IBANID></ram:PayeePartyCreditorFinancialAccount>
      </ram:SpecifiedTradeSettlementPaymentMeans>
      <ram:SpecifiedTradePaymentTerms><ram:DueDateDateTime><udt:DateTimeString format="102">20261015</udt:DateTimeString></ram:DueDateDateTime></ram:SpecifiedTradePaymentTerms>
      <ram:SpecifiedTradeSettlementHeaderMonetarySummation>
        <ram:LineTotalAmount>119.64</ram:LineTotalAmount><ram:TaxTotalAmount currencyID="EUR">22.73</ram:TaxTotalAmount>
        <ram:GrandTotalAmount>142.37</ram:GrandTotalAmount><ram:DuePayableAmount>142.37</ram:DuePayableAmount>
      </ram:SpecifiedTradeSettlementHeaderMonetarySummation>
    </ram:ApplicableHeaderTradeSettlement>
  </rsm:SupplyChainTradeTransaction>
</rsm:CrossIndustryInvoice>''';

/// XRechnung (UBL).
const ubl = '''<?xml version="1.0" encoding="UTF-8"?>
<ubl:Invoice xmlns:ubl="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
  xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
  xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0</cbc:CustomizationID>
  <cbc:ID>2026-4711</cbc:ID>
  <cbc:IssueDate>2026-05-18</cbc:IssueDate>
  <cbc:DueDate>2026-06-01</cbc:DueDate>
  <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
  <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
  <cac:AccountingSupplierParty><cac:Party><cac:PartyName><cbc:Name>Elektro Becker GmbH</cbc:Name></cac:PartyName></cac:Party></cac:AccountingSupplierParty>
  <cac:AccountingCustomerParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Alex Beispiel</cbc:RegistrationName></cac:PartyLegalEntity></cac:Party></cac:AccountingCustomerParty>
  <cac:PaymentMeans><cbc:PaymentMeansCode>58</cbc:PaymentMeansCode><cac:PayeeFinancialAccount><cbc:ID>DE02 1203 0000 0000 2020 51</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>
  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="EUR">327.65</cbc:LineExtensionAmount>
    <cbc:TaxInclusiveAmount currencyID="EUR">389.90</cbc:TaxInclusiveAmount>
    <cbc:PayableAmount currencyID="EUR">389.90</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>
  <cac:InvoiceLine><cbc:ID>1</cbc:ID><cbc:InvoicedQuantity unitCode="HUR">3.5</cbc:InvoicedQuantity><cbc:LineExtensionAmount currencyID="EUR">245.00</cbc:LineExtensionAmount><cac:Item><cbc:Name>Arbeitszeit Elektriker</cbc:Name></cac:Item></cac:InvoiceLine>
  <cac:InvoiceLine><cbc:ID>2</cbc:ID><cbc:InvoicedQuantity unitCode="C62">1</cbc:InvoicedQuantity><cbc:LineExtensionAmount currencyID="EUR">82.65</cbc:LineExtensionAmount><cac:Item><cbc:Name>Material</cbc:Name></cac:Item></cac:InvoiceLine>
</ubl:Invoice>''';

const germanText = '''Elektro Becker GmbH · Hauptstraße 12 · 12345 Musterstadt
Rechnung
Rechnungsnummer: RE-2026-0042
Rechnungsdatum: 18.05.2026
Pos. Beschreibung Betrag
1 Arbeitszeit 245,00 €
2 Material 82,65 €
Zwischensumme 327,65 €
zzgl. 19 % MwSt 62,25 €
Gesamtbetrag 389,90 €
Zahlbar innerhalb von 14 Tagen ohne Abzug.
Bankverbindung: Musterbank IBAN DE89 3704 0044 0532 0130 00 BIC COBADEFFXXX''';

void main() {
  group('E-Rechnung', () {
    test('Factur-X/ZUGFeRD (CII)', () {
      final d = parseInvoiceXml(cii)!;
      expect(d.syntax, 'CII');
      expect(d.number, 'RE-2026-0815');
      expect(d.issueDate, DateTime(2026, 9, 15));
      expect(d.dueDate, DateTime(2026, 10, 15));
      expect(d.monetary, 'EUR142.37');
      expect(d.iban, 'DE89370400440532013000');
      expect(d.seller, 'Stadtwerke Musterstadt');
      expect(d.buyer, 'Alex Beispiel');
      expect(d.lines.single.name, 'Strom Jahresabrechnung');
      expect(d.lines.single.unit, 'KWH');
      expect(d.lines.single.amount, '119.64');
    });

    test('XRechnung (UBL) mit Text und PDF zum Ansehen', () async {
      final d = parseInvoiceXml(ubl)!;
      expect(d.syntax, 'UBL');
      expect([d.number, d.monetary, d.iban, d.seller], ['2026-4711', 'EUR389.90', 'DE02120300000000202051', 'Elektro Becker GmbH']);
      expect(d.dueDate, DateTime(2026, 6, 1));
      expect(d.lines.map((l) => l.name), ['Arbeitszeit Elektriker', 'Material']);
      final summary = invoiceSummary(d);
      expect(summary, contains('Gesamtbetrag / Total: 389,90 EUR'));
      expect(summary, contains('3.5 HUR × Arbeitszeit Elektriker: 245,00 EUR'));
      final pdf = await invoicePdf(d);
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    test('kein XML oder keine Rechnung', () {
      expect(parseInvoiceXml('kein xml'), isNull);
      expect(parseInvoiceXml('<root><a/></root>'), isNull);
    });
  });

  group('Text', () {
    test('deutsche Rechnung: Nummer, Datum, Zahlungsziel, Gesamtbetrag, IBAN', () {
      final d = invoiceFromText(germanText)!;
      expect(d.number, 'RE-2026-0042');
      expect(d.issueDate, DateTime(2026, 5, 18));
      expect(d.dueDate, DateTime(2026, 6, 1), reason: '14 Tage nach Rechnungsdatum');
      expect(d.monetary, 'EUR389.90', reason: 'Gesamtbetrag, nicht Zwischensumme oder MwSt');
      expect(d.iban, 'DE89370400440532013000');
    });

    test('englische Rechnung', () {
      final d = invoiceFromText('ACME Ltd.\nInvoice No: INV-1001\nInvoice date: 2026-03-02\n'
          'Subtotal 1,100.00\nTotal due: \$1,234.50\nDue date: March 16, 2026')!;
      expect(d.number, 'INV-1001');
      expect(d.issueDate, DateTime(2026, 3, 2));
      expect(d.dueDate, DateTime(2026, 3, 16));
      expect(d.monetary, 'USD1234.50');
    });

    test('kein Rechnungstext, ungültige IBAN', () {
      expect(invoiceFromText('Kontoauszug Nr. 9\nBetrag 2.104,18 EUR\nIBAN DE89 3704 0044 0532 0130 00'), isNull);
      expect(invoiceFromText('Mietvertrag mit Nebenkostenabrechnung, Kaltmiete 820,00 EUR'), isNull);
      expect(findIban('IBAN DE89 3704 0044 0532 0130 01'), isNull);
      expect(isValidIban('DE02 1203 0000 0000 2020 51'), isTrue);
    });
  });

  group('Verarbeitung', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() => env.close());

    Future<Map<String, dynamic>> fieldsOf(int id) async {
      final names = {
        for (final f in (await env.json('GET', '/api/custom_fields/'))['results']) f['id']: f['name'],
      };
      final doc = await env.json('GET', '/api/documents/$id/');
      return {for (final f in doc['custom_fields']) names[f['field']]: f['value']};
    }

    test('Rechnungstext: Felder angelegt und gefüllt, Belegdatum aus dem Rechnungsdatum', () async {
      final id = (await env.uploadText('becker.txt', germanText))!;
      expect(await fieldsOf(id), {
        'Rechnungsbetrag': 'EUR389.90',
        'Rechnungsnummer': 'RE-2026-0042',
        'Fällig am': '2026-06-01',
        'IBAN': 'DE89370400440532013000',
      });
      expect((await env.json('GET', '/api/documents/$id/'))['created'], startsWith('2026-05-18'));

      // Umbenennen ist erlaubt; das nächste Dokument nutzt dasselbe Feld.
      final amountField = env.server.db.select("SELECT id FROM custom_fields WHERE name = 'Rechnungsbetrag'").first['id'];
      await env.json('PATCH', '/api/custom_fields/$amountField/', body: {'name': 'Betrag'});
      final next = (await env.uploadText('becker2.txt', germanText.replaceAll('0042', '0043').replaceAll('389,90', '12,00')))!;
      expect((await fieldsOf(next))['Betrag'], 'EUR12.00');
      expect(env.server.db.select('SELECT COUNT(*) AS n FROM custom_fields').first['n'], 4);
    });

    test('vorhandene Werte bleiben beim Neuverarbeiten', () async {
      final id = (await env.uploadText('becker.txt', germanText))!;
      final numberField = env.server.db.select("SELECT id FROM custom_fields WHERE name = 'Rechnungsnummer'").first['id'];
      await env.json('PATCH', '/api/documents/$id/', body: {
        'custom_fields': [
          {'field': numberField, 'value': 'Von Hand'},
        ],
      });
      await env.server.consumer.reprocess(id);
      expect((await fieldsOf(id))['Rechnungsnummer'], 'Von Hand');
    });

    test('XRechnung als XML: lesbar, Archiv-PDF, Titel und Korrespondent', () async {
      await env.json('POST', '/api/correspondents/', status: 201, body: {'name': 'Elektro Becker GmbH', 'matching_algorithm': 0});
      final id = (await env.upload('xrechnung.xml', utf8.encode(ubl)))!;
      final doc = await env.json('GET', '/api/documents/$id/');
      expect(doc['mime_type'], 'application/xml');
      expect(doc['title'], 'Elektro Becker GmbH 2026-4711');
      expect(doc['created'], startsWith('2026-05-18'));
      expect(doc['content'], contains('Gesamtbetrag / Total: 389,90 EUR'));
      final correspondents = (await env.json('GET', '/api/correspondents/'))['results'] as List;
      expect(correspondents.firstWhere((c) => c['id'] == doc['correspondent'])['name'], 'Elektro Becker GmbH');
      expect(env.server.db.select('SELECT archive_path FROM documents WHERE id = ?', [id]).first['archive_path'], isNotNull);
      expect(await fieldsOf(id), containsPair('Rechnungsbetrag', 'EUR389.90'));
    });

    test('abschaltbar', () async {
      final off = await TestEnv.create(env: {'PAPERBUDDY_INVOICE_FIELDS': 'false'});
      addTearDown(off.close);
      await off.uploadText('becker.txt', germanText);
      expect(off.server.db.select('SELECT COUNT(*) AS n FROM custom_fields').first['n'], 0);
    });
  });

  final qpdf = Process.runSync('which', ['qpdf']).exitCode == 0;
  test('ZUGFeRD: eingebettetes XML im PDF', () async {
    final dir = await Directory.systemTemp.createTemp('paperbuddy-zugferd-');
    addTearDown(() => dir.delete(recursive: true));
    final doc = pw.Document()..addPage(pw.Page(build: (_) => pw.Text('Rechnung RE-2026-0815')));
    File('${dir.path}/plain.pdf').writeAsBytesSync(await doc.save());
    File('${dir.path}/factur-x.xml').writeAsStringSync(cii);
    final r = Process.runSync('qpdf', [
      '${dir.path}/plain.pdf', '--add-attachment', '${dir.path}/factur-x.xml', '--key=factur-x.xml', '--', '${dir.path}/zugferd.pdf',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final xml = await ExternalTools(ocrLanguage: 'deu').pdfInvoiceXml('${dir.path}/zugferd.pdf');
    expect(parseInvoiceXml(xml!)!.number, 'RE-2026-0815');
    expect(await ExternalTools(ocrLanguage: 'deu').pdfInvoiceXml('${dir.path}/plain.pdf'), isNull);
  }, skip: qpdf ? false : 'qpdf nicht installiert');
}
