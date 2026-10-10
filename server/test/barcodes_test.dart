import 'dart:io';

import 'package:paperbuddy_server/paperbuddy_server.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:test/test.dart';

import 'helpers.dart';

const _split = BarcodeSettings(split: true, asn: true);

void main() {
  group('Aufteilung', () {
    test('ohne Barcodes bleibt alles ein Dokument', () {
      expect(planBarcodeSplit([[], [], []], 3, _split), [const BarcodePart(1, 3)]);
    });

    test('Trennblätter fallen weg, auch am Anfang und Ende', () {
      expect(planBarcodeSplit([[], [], ['PATCHT'], [], []], 5, _split), [const BarcodePart(1, 2), const BarcodePart(4, 5)]);
      expect(planBarcodeSplit([['PATCHT'], [], [], ['PATCHT']], 4, _split), [const BarcodePart(2, 3)]);
      expect(planBarcodeSplit([['PATCHT'], ['PATCHT']], 2, _split), isEmpty);
    });

    test('ASN-Seite beginnt ein neues Dokument und gibt ihm die Nummer', () {
      expect(
        planBarcodeSplit([[], ['ASN00042'], [], ['PATCHT'], ['ASN 7']], 5, _split),
        [const BarcodePart(1, 1), const BarcodePart(2, 3, 42), const BarcodePart(5, 5, 7)],
      );
    });

    test('nur ASN: ein Dokument mit der ersten Nummer', () {
      const asnOnly = BarcodeSettings(asn: true);
      expect(planBarcodeSplit([[], ['ASN0005'], ['PATCHT', 'ASN0006']], 3, asnOnly), [const BarcodePart(1, 3, 5)]);
    });

    test('nur die ersten Seiten durchsucht, eigener Trenncode', () {
      const custom = BarcodeSettings(split: true, separator: 'TRENNER');
      expect(planBarcodeSplit([[], ['TRENNER']], 6, custom), [const BarcodePart(1, 1), const BarcodePart(3, 6)]);
    });

    test('ASN aus dem Code', () {
      expect(asnFromCode('ASN00042', 'ASN'), 42);
      expect(asnFromCode('asn-123', 'ASN'), 123);
      expect(asnFromCode('ASN', 'ASN'), isNull);
      expect(asnFromCode('PATCHT', 'ASN'), isNull);
      expect(asnFromCode('ASNABC', 'ASN'), isNull);
    });
  });

  final tools = ['pdftoppm', 'pdfinfo', 'zbarimg', 'qpdf'].every((t) => Process.runSync('which', [t]).exitCode == 0);
  test('Stapelscan mit Trennblatt und ASN-Barcode', () async {
    final env = await TestEnv.create(env: {
      'PAPERBUDDY_CONSUMER_ENABLE_BARCODES': 'true',
      'PAPERLESS_CONSUMER_ENABLE_ASN_BARCODE': 'true',
    });
    addTearDown(env.close);
    pw.Widget page(String text, [String? code]) => pw.Column(children: [
      pw.Text(text),
      if (code != null) ...[
        pw.SizedBox(height: 40),
        pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: code, width: 320, height: 110),
      ],
    ]);
    final doc = pw.Document();
    for (final (text, code) in [
      ('Mietvertrag Seite eins', null),
      ('Mietvertrag Seite zwei', null),
      ('Trennblatt', 'PATCHT'),
      ('Stromrechnung Seite eins', 'ASN00042'),
      ('Stromrechnung Seite zwei', null),
    ]) {
      doc.addPage(pw.Page(build: (_) => page(text, code)));
    }
    final id = await env.upload('stapel.pdf', await doc.save());
    expect(id, isNull, reason: 'der Stapel selbst wird kein Dokument');
    expect(env.lastTaskResult, startsWith('Split into 2 documents'));
    await env.server.consumer.idle();

    final docs = env.server.db.select('SELECT title, archive_serial_number, page_count, content FROM documents ORDER BY title');
    expect([for (final d in docs) d['title']], ['stapel_1', 'stapel_2']);
    expect([for (final d in docs) d['page_count']], [2, 2]);
    expect(docs.first['content'], contains('Mietvertrag'));
    expect(docs.first['content'], isNot(contains('Trennblatt')));
    expect(docs.last['content'], contains('Stromrechnung'));
    expect([for (final d in docs) d['archive_serial_number']], [null, 42]);
  }, skip: tools ? false : 'pdftoppm, pdfinfo, zbarimg oder qpdf fehlt');
}
