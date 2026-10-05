import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:paperbuddy_server/src/processing/file_types.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Uint8List zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, content) {
    final data = utf8.encode(content);
    a.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(a));
}

const _ct = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>';

Uint8List docx(String text) => zip({
      '[Content_Types].xml': _ct,
      'word/document.xml': '<w:document xmlns:w="w"><w:body>'
          '<w:p><w:r><w:t>$text</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Zweite</w:t><w:tab/><w:t>Zeile</w:t></w:r></w:p>'
          '</w:body></w:document>',
    });

Uint8List xlsx() => zip({
      '[Content_Types].xml': _ct,
      'xl/sharedStrings.xml': '<sst><si><t>Posten</t></si><si><t>Strom</t></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
          '<row><c t="s"><v>0</v></c><c t="inlineStr"><is><t>Betrag</t></is></c></row>'
          '<row><c t="s"><v>1</v></c><c><v>84.2</v></c></row>'
          '</sheetData></worksheet>',
    });

Uint8List pptx() => zip({
      '[Content_Types].xml': _ct,
      'ppt/slides/slide2.xml': '<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Folie zwei</a:t></a:r></a:p></p:sld>',
      'ppt/slides/slide1.xml': '<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Folie eins</a:t></a:r></a:p></p:sld>',
    });

Uint8List odt() => zip({
      'mimetype': 'application/vnd.oasis.opendocument.text',
      'content.xml': '<office:document-content xmlns:office="o" xmlns:text="t"><office:body><office:text>'
          '<text:h>Kündigung</text:h><text:p>Hiermit kündige ich zum 31.12.2026.</text:p>'
          '</office:text></office:body></office:document-content>',
    });

void main() {
  test('Typ nach Inhalt, auch bei falscher Endung', () {
    expect(detectFileType('scan.txt', ascii.encode('%PDF-1.7\n...')), 'application/pdf');
    expect(detectFileType('foto.pdf', [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]), 'image/jpeg');
    expect(detectFileType('bild', [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]), 'image/png');
    expect(detectFileType('a.tif', [0x49, 0x49, 0x2A, 0x00, 8, 0]), 'image/tiff');
    expect(detectFileType('x.bin', [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBPVP8 ')]), 'image/webp');
    expect(detectFileType('vertrag.pdf', docx('Hallo')),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    expect(detectFileType('tabelle.zip', xlsx()), 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    expect(detectFileType('folien', pptx()), 'application/vnd.openxmlformats-officedocument.presentationml.presentation');
    expect(detectFileType('brief.docx', odt()), 'application/vnd.oasis.opendocument.text');
    expect(detectFileType('alt.doc', [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0]), 'application/msword');
    expect(detectFileType('alt.xls', [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0]), 'application/vnd.ms-excel');
    expect(detectFileType('notiz.pdf', utf8.encode('Grüße aus München\nZeile 2')), 'text/plain');
    expect(detectFileType('daten.csv', utf8.encode('a;b\n1;2')), 'text/csv');
    expect(detectFileType('archiv.zip', zip({'a.txt': 'x'})), 'application/zip');
    expect(detectFileType('x.dat', [0, 1, 2, 3, 0, 0, 7]), 'application/octet-stream');
  });

  test('Text aus Office-Dateien', () {
    const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    expect(officeText(docx('Mietvertrag Wohnung'), docxMime), 'Mietvertrag Wohnung\nZweite\tZeile');
    expect(officeText(xlsx(), 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
        'Posten\tBetrag\nStrom\t84.2');
    expect(officeText(pptx(), 'application/vnd.openxmlformats-officedocument.presentationml.presentation'),
        'Folie eins\nFolie zwei');
    expect(officeText(odt(), 'application/vnd.oasis.opendocument.text'),
        'Kündigung\nHiermit kündige ich zum 31.12.2026.');
    expect(officeText(Uint8List(4), 'application/msword'), isNull);
  });

  test('Upload: DOCX mit falscher Endung wird erkannt und durchsuchbar', () async {
    final env = await TestEnv.create();
    addTearDown(env.close);
    final id = await env.upload('angebot.pdf', docx('Angebot Dachdecker Musterstadt'));
    expect(id, isNotNull);
    final doc = await env.json('GET', '/api/documents/$id/');
    expect(doc['mime_type'], 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    final hits = await env.json('GET', '/api/documents/?query=dachdecker');
    expect(hits['count'], 1);
    final stats = await env.json('GET', '/api/statistics/');
    expect((stats['document_file_type_counts'] as List).single['mime_type'], doc['mime_type']);
  });
}
