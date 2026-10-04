import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:xml/xml.dart';

import '../access.dart';
import '../api/http_utils.dart';
import '../auth.dart';
import '../processing/consumer.dart';

final _log = Logger('scanner');

class Scanner {
  Scanner(this.id, this.name, this.url, {required this.discovered});
  final String id;
  final String name;

  /// Basis-URL der eSCL-Schnittstelle, z. B. `http://192.168.1.20/eSCL`.
  final Uri url;
  final bool discovered;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url.toString(),
        'source': discovered ? 'discovered' : 'configured',
      };
}

class ScannerCapabilities {
  ScannerCapabilities({
    required this.makeAndModel,
    required this.sources,
    required this.colorModes,
    required this.resolutions,
    required this.formats,
    required this.duplex,
  });

  final String makeAndModel;

  /// `Platen` (Glas) und/oder `Feeder` (Einzug).
  final List<String> sources;
  final List<String> colorModes;
  final List<int> resolutions;
  final List<String> formats;
  final bool duplex;

  Map<String, dynamic> toJson() => {
        'make_and_model': makeAndModel,
        'sources': sources,
        'color_modes': colorModes,
        'resolutions': resolutions,
        'formats': formats,
        'duplex': duplex,
      };

  static ScannerCapabilities parse(String xml) {
    final doc = XmlDocument.parse(xml);
    Iterable<String> texts(String local) =>
        doc.descendants.whereType<XmlElement>().where((e) => e.name.local == local).map((e) => e.innerText.trim());
    final sources = <String>[
      if (doc.descendants.whereType<XmlElement>().any((e) => e.name.local == 'Platen')) 'Platen',
      if (doc.descendants.whereType<XmlElement>().any((e) => e.name.local == 'Adf')) 'Feeder',
    ];
    return ScannerCapabilities(
      makeAndModel: texts('MakeAndModel').firstOrNull ?? '',
      sources: sources,
      colorModes: texts('ColorMode').toSet().toList(),
      resolutions: (texts('XResolution').map(int.tryParse).whereType<int>().toSet().toList()..sort()),
      formats: {...texts('DocumentFormatExt'), ...texts('DocumentFormat')}.toList(),
      duplex: doc.descendants.whereType<XmlElement>().any((e) => e.name.local == 'AdfDuplexInputCaps'),
    );
  }
}

/// Netzwerkscanner über eSCL (AirScan/Mopria): finden und scannen.
class ScannerService {
  ScannerService({
    required this.access,
    required this.consumer,
    required this.workDir,
    this.configured = const [],
    this.discover = true,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Access access;
  final Consumer consumer;
  final String workDir;
  final List<Scanner> configured;
  final bool discover;
  final http.Client _http;
  List<Scanner> _discovered = [];
  DateTime? _lastDiscovery;

  /// `Büro=http://192.168.1.20/eSCL;Keller=http://scanner.local:8080/eSCL`
  static List<Scanner> parseConfig(String? raw) => [
        for (final entry in (raw ?? '').split(';').map((s) => s.trim()).where((s) => s.isNotEmpty))
          if (entry.contains('='))
            Scanner(
              slugify(entry.substring(0, entry.indexOf('=')).trim()),
              entry.substring(0, entry.indexOf('=')).trim(),
              Uri.parse(entry.substring(entry.indexOf('=') + 1).trim().replaceAll(RegExp(r'/+$'), '')),
              discovered: false,
            ),
      ];

  Future<List<Scanner>> scanners({bool refresh = false}) async {
    if (discover &&
        (refresh || _lastDiscovery == null || DateTime.now().difference(_lastDiscovery!) > const Duration(minutes: 5))) {
      try {
        _discovered = await _discoverMdns();
      } catch (e) {
        _log.fine('mDNS-Suche nicht möglich: $e');
      }
      _lastDiscovery = DateTime.now();
    }
    final known = configured.map((s) => s.url.toString()).toSet();
    return [...configured, ..._discovered.where((s) => !known.contains(s.url.toString()))];
  }

  Future<List<Scanner>> _discoverMdns() async {
    final client = MDnsClient();
    await client.start();
    final found = <String, Scanner>{};
    try {
      for (final (service, scheme) in [('_uscan._tcp.local', 'http'), ('_uscans._tcp.local', 'https')]) {
        await for (final ptr in client
            .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service))
            .timeout(const Duration(seconds: 3), onTimeout: (sink) => sink.close())) {
          final instance = ptr.domainName;
          String path = 'eSCL';
          await for (final txt in client
              .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance))
              .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
            final rs = RegExp(r'rs=([^\s]+)').firstMatch(txt.text)?.group(1);
            if (rs != null) path = rs;
          }
          await for (final srv in client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(instance))
              .timeout(const Duration(seconds: 2), onTimeout: (sink) => sink.close())) {
            final name = instance.split('._').first;
            final host = srv.target.replaceAll(RegExp(r'\.$'), '');
            final url = Uri(scheme: scheme, host: host, port: srv.port, path: '/${path.replaceAll(RegExp(r'^/+'), '')}');
            found[url.toString()] = Scanner(slugify(name), name, url, discovered: true);
          }
        }
      }
    } finally {
      client.stop();
    }
    return found.values.toList();
  }

  Future<ScannerCapabilities> capabilities(Scanner s) async {
    final r = await _http.get(Uri.parse('${s.url}/ScannerCapabilities')).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw ApiError(502, 'Scanner antwortet mit ${r.statusCode}.');
    return ScannerCapabilities.parse(utf8.decode(r.bodyBytes));
  }

  static String scanSettingsXml({
    required String source,
    required String colorMode,
    required int resolution,
    required String format,
    bool duplex = false,
  }) {
    final inputSource = source == 'Feeder' ? 'Feeder' : 'Platen';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.6</pwg:Version>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
      <pwg:Width>2480</pwg:Width>
      <pwg:Height>3508</pwg:Height>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>$inputSource</pwg:InputSource>
  <scan:ColorMode>$colorMode</scan:ColorMode>
  <scan:XResolution>$resolution</scan:XResolution>
  <scan:YResolution>$resolution</scan:YResolution>
  <pwg:DocumentFormat>$format</pwg:DocumentFormat>
  <scan:DocumentFormatExt>$format</scan:DocumentFormatExt>
  ${source == 'Feeder' && duplex ? '<scan:Duplex>true</scan:Duplex>' : ''}
</scan:ScanSettings>''';
  }

  /// Scannt alle Seiten und gibt sie als ein Dokument an den Consumer.
  Future<String> scan(
    Scanner s, {
    String source = 'Platen',
    String colorMode = 'RGB24',
    int resolution = 300,
    bool duplex = false,
    ConsumeOverrides? overrides,
  }) async {
    final caps = await capabilities(s);
    final format = caps.formats.contains('application/pdf') ? 'application/pdf' : 'image/jpeg';
    final mode = caps.colorModes.isEmpty || caps.colorModes.contains(colorMode) ? colorMode : caps.colorModes.first;
    final res = caps.resolutions.isEmpty || caps.resolutions.contains(resolution)
        ? resolution
        : caps.resolutions.reduce((a, b) => (a - resolution).abs() <= (b - resolution).abs() ? a : b);

    final job = await _http
        .post(
          Uri.parse('${s.url}/ScanJobs'),
          headers: {'content-type': 'text/xml'},
          body: scanSettingsXml(source: source, colorMode: mode, resolution: res, format: format, duplex: duplex),
        )
        .timeout(const Duration(seconds: 30));
    if (job.statusCode != 201) {
      throw ApiError(job.statusCode == 503 ? 409 : 502, 'Scanner lehnt den Auftrag ab (${job.statusCode}).');
    }
    final location = job.headers['location'] ?? (throw ApiError(502, 'Scanner liefert keine Auftrags-URL.'));
    final jobUrl = s.url.resolve(location);

    final pages = <Uint8List>[];
    String? pageType;
    for (var attempt = 0; attempt < 500; attempt++) {
      final r = await _http
          .get(Uri.parse('${jobUrl.toString().replaceAll(RegExp(r'/+$'), '')}/NextDocument'))
          .timeout(const Duration(minutes: 2));
      if (r.statusCode == 200) {
        pages.add(r.bodyBytes);
        pageType = (r.headers['content-type'] ?? format).split(';').first;
        // Flachbett liefert genau eine Seite.
        if (source != 'Feeder' || pageType == 'application/pdf') break;
        continue;
      }
      if (r.statusCode == 503) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      break; // 404: keine weiteren Seiten
    }
    if (pages.isEmpty) throw ApiError(502, 'Der Scanner hat keine Seite geliefert.');

    final Uint8List file;
    final String ext;
    if (pageType == 'application/pdf' && pages.length == 1) {
      file = pages.single;
      ext = 'pdf';
    } else if (pageType == 'application/pdf') {
      // Selten: mehrere PDFs. Erstes nehmen, Rest als eigene Dokumente.
      file = pages.first;
      ext = 'pdf';
    } else {
      file = await imagesToPdf(pages);
      ext = 'pdf';
    }
    final dir = await Directory(p.join(workDir, 'scans')).create(recursive: true);
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    final name = 'Scan ${s.name} $stamp.$ext';
    final tmp = File(p.join(dir.path, name));
    await tmp.writeAsBytes(file);
    return consumer.submit(tmp, originalName: name, moveSource: true, source: ConsumeSource.scanner, overrides: overrides);
  }

  static Future<Uint8List> imagesToPdf(List<Uint8List> pages) async {
    final doc = pw.Document(creator: 'PaperBuddy');
    for (final bytes in pages) {
      final image = pw.MemoryImage(bytes);
      final w = (image.width ?? 2480).toDouble(), h = (image.height ?? 3508).toDouble();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(PdfPageFormat.a4.width, PdfPageFormat.a4.width * h / w),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, fit: pw.BoxFit.contain),
      ));
    }
    return doc.save();
  }

  // API ------------------------------------------------------------------------

  User _user(Request r) => r.context['user'] as User;

  Future<Scanner> _find(Request request) async {
    final id = request.params['id']!;
    return (await scanners()).where((s) => s.id == id).firstOrNull ?? (throw ApiError(404, 'Scanner not found.'));
  }

  Future<Response> _list(Request request) async {
    access.require(_user(request), 'add', 'document');
    final list = await scanners(refresh: asBool(request.url.queryParameters['refresh']));
    return json([for (final s in list) s.toJson()]);
  }

  Future<Response> _capabilities(Request request) async {
    access.require(_user(request), 'add', 'document');
    try {
      return json((await capabilities(await _find(request))).toJson());
    } on TimeoutException {
      throw ApiError(504, 'Der Scanner antwortet nicht.');
    } on SocketException catch (e) {
      throw ApiError(502, 'Scanner nicht erreichbar: ${e.message}');
    }
  }

  Future<Response> _scan(Request request) async {
    final user = _user(request);
    access.require(user, 'add', 'document');
    final scanner = await _find(request);
    final body = await readBody(request);
    try {
      final task = await scan(
        scanner,
        source: '${body['source'] ?? 'Platen'}',
        colorMode: '${body['color_mode'] ?? 'RGB24'}',
        resolution: asInt(body['resolution']) ?? 300,
        duplex: asBool(body['duplex']),
        overrides: ConsumeOverrides(
          title: body['title'] as String?,
          correspondent: asInt(body['correspondent']),
          documentType: asInt(body['document_type']),
          storagePath: asInt(body['storage_path']),
          tags: asIntList(body['tags']),
          owner: user.id,
        ),
      );
      return json(task);
    } on TimeoutException {
      throw ApiError(504, 'Der Scanner antwortet nicht.');
    } on SocketException catch (e) {
      throw ApiError(502, 'Scanner nicht erreichbar: ${e.message}');
    }
  }

  void mount(void Function(String method, String path, Function handler) route) {
    route('GET', '/api/scanners/', _list);
    route('GET', '/api/scanners/<id>/capabilities/', _capabilities);
    route('POST', '/api/scanners/<id>/scan/', _scan);
  }

  void close() => _http.close();
}
