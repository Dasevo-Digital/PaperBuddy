import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'storage.dart';

final _log = Logger('storage');

/// Gemeinsame Basis für entfernte Speicher: Dateien werden lokal
/// zwischengespeichert, damit Vorschau und Download schnell bleiben.
abstract class CachedRemoteStore implements BlobStore {
  CachedRemoteStore(this.cacheDir, {this.maxCacheBytes = 500 * 1024 * 1024});

  final String cacheDir;
  final int maxCacheBytes;

  Future<void> upload(String key, File source);
  Future<bool> download(String key, File target);
  Future<void> remove(String key);

  File _cached(String key) {
    final full = p.normalize(p.join(cacheDir, key));
    if (!p.isWithin(cacheDir, full)) throw ArgumentError('Ungültiger Speicherpfad: $key');
    return File(full);
  }

  @override
  Future<void> put(String key, File source) async {
    await upload(key, source);
    final cached = _cached(key);
    await cached.parent.create(recursive: true);
    await source.copy(cached.path);
    await _trimCache();
  }

  @override
  Future<File?> get(String key) async {
    final cached = _cached(key);
    if (await cached.exists()) {
      // Zugriffszeit für die Aufräumreihenfolge
      await cached.setLastModified(DateTime.now());
      return cached;
    }
    await cached.parent.create(recursive: true);
    final tmp = File('${cached.path}.part');
    if (!await download(key, tmp)) {
      if (await tmp.exists()) await tmp.delete();
      return null;
    }
    await tmp.rename(cached.path);
    await _trimCache();
    return cached;
  }

  @override
  Future<void> delete(String key) async {
    await remove(key);
    final cached = _cached(key);
    if (await cached.exists()) await cached.delete();
  }

  /// Älteste Dateien entfernen, bis der Zwischenspeicher klein genug ist.
  Future<void> _trimCache() async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) return;
    final files = <(File, int, DateTime)>[];
    var total = 0;
    await for (final e in dir.list(recursive: true)) {
      if (e is File && !e.path.endsWith('.part')) {
        final st = await e.stat();
        files.add((e, st.size, st.modified));
        total += st.size;
      }
    }
    if (total <= maxCacheBytes) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (f, size, _) in files) {
      if (total <= maxCacheBytes) break;
      await f.delete();
      total -= size;
    }
  }
}

/// S3-kompatibler Speicher (AWS, MinIO, Wasabi, Backblaze B2 …), signiert
/// mit AWS Signature Version 4.
class S3BlobStore extends CachedRemoteStore {
  S3BlobStore({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.prefix = '',
    this.pathStyle = true,
    required String cacheDir,
    int maxCacheBytes = 500 * 1024 * 1024,
    http.Client? client,
  })  : _http = client ?? http.Client(),
        super(cacheDir, maxCacheBytes: maxCacheBytes);

  final Uri endpoint;
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String prefix;
  final bool pathStyle;
  final http.Client _http;

  Uri _url(String key) {
    final objectKey = [if (prefix.isNotEmpty) prefix.replaceAll(RegExp(r'^/+|/+$'), ''), key].join('/');
    final encoded = objectKey.split('/').map(_uriEncode).join('/');
    return pathStyle
        ? endpoint.replace(path: '${endpoint.path.replaceAll(RegExp(r'/+$'), '')}/$bucket/$encoded')
        : endpoint.replace(host: '$bucket.${endpoint.host}', path: '/$encoded');
  }

  /// Kodierung nach AWS-Vorgabe (RFC 3986, ohne `/` im Segment).
  static String _uriEncode(String s) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      if (RegExp(r'[A-Za-z0-9\-._~]').hasMatch(c)) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  Map<String, String> _sign(String method, Uri url, String payloadHash, {DateTime? now}) {
    final t = (now ?? DateTime.now()).toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${t.year}${two(t.month)}${two(t.day)}';
    final amzDate = '${date}T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    final host = url.hasPort && url.port != 80 && url.port != 443 ? '${url.host}:${url.port}' : url.host;
    final headers = {'host': host, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate};
    final signedHeaders = headers.keys.toList()..sort();
    final canonical = [
      method,
      url.path.isEmpty ? '/' : url.path,
      '',
      for (final h in signedHeaders) '$h:${headers[h]}',
      '',
      signedHeaders.join(';'),
      payloadHash,
    ].join('\n');
    final scope = '$date/$region/s3/aws4_request';
    final toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256.convert(utf8.encode(canonical)).toString()].join('\n');
    List<int> hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    final kSigning = hmac(hmac(hmac(hmac(utf8.encode('AWS4$secretKey'), date), region), 's3'), 'aws4_request');
    final signature = Hmac(sha256, kSigning).convert(utf8.encode(toSign)).toString();
    return {
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      'authorization': 'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
          'SignedHeaders=${signedHeaders.join(';')}, Signature=$signature',
    };
  }

  static const _emptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  @override
  Future<void> upload(String key, File source) async {
    final bytes = await source.readAsBytes();
    final url = _url(key);
    final r = await _http.put(url, headers: _sign('PUT', url, sha256.convert(bytes).toString()), body: bytes);
    if (r.statusCode >= 300) throw HttpException('S3 PUT $key: ${r.statusCode} ${r.body}');
  }

  @override
  Future<bool> download(String key, File target) async {
    final url = _url(key);
    final request = http.Request('GET', url)..headers.addAll(_sign('GET', url, _emptyHash));
    final r = await _http.send(request);
    if (r.statusCode == 404) {
      await r.stream.drain<void>();
      return false;
    }
    if (r.statusCode >= 300) {
      throw HttpException('S3 GET $key: ${r.statusCode} ${await r.stream.bytesToString()}');
    }
    final sink = target.openWrite();
    await r.stream.pipe(sink);
    return true;
  }

  @override
  Future<void> remove(String key) async {
    final url = _url(key);
    final r = await _http.delete(url, headers: _sign('DELETE', url, _emptyHash));
    if (r.statusCode >= 300 && r.statusCode != 404) throw HttpException('S3 DELETE $key: ${r.statusCode}');
  }

  /// Für den Start: prüft Zugangsdaten und Bucket.
  Future<void> check() async {
    final url = pathStyle
        ? endpoint.replace(path: '${endpoint.path.replaceAll(RegExp(r'/+$'), '')}/$bucket')
        : endpoint.replace(host: '$bucket.${endpoint.host}', path: '/');
    final r = await _http.head(url, headers: _sign('HEAD', url, _emptyHash));
    if (r.statusCode >= 300) throw HttpException('S3-Bucket $bucket nicht erreichbar: ${r.statusCode}');
    _log.info('S3-Speicher: $endpoint, Bucket $bucket');
  }
}

/// WebDAV-Speicher, z. B. Nextcloud
/// (`https://cloud.example.org/remote.php/dav/files/<user>/PaperBuddy`).
class WebDavBlobStore extends CachedRemoteStore {
  WebDavBlobStore({
    required this.baseUrl,
    required this.username,
    required this.password,
    required String cacheDir,
    int maxCacheBytes = 500 * 1024 * 1024,
    http.Client? client,
  })  : _http = client ?? http.Client(),
        super(cacheDir, maxCacheBytes: maxCacheBytes);

  final Uri baseUrl;
  final String username;
  final String password;
  final http.Client _http;
  final _knownDirs = <String>{};

  Map<String, String> get _auth => {'authorization': 'Basic ${base64.encode(utf8.encode('$username:$password'))}'};

  Uri _url(String key) => baseUrl.replace(
        path: '${baseUrl.path.replaceAll(RegExp(r'/+$'), '')}/${key.split('/').map(Uri.encodeComponent).join('/')}',
      );

  Future<void> _ensureDirs(String key) async {
    final parts = p.posix.split(p.posix.dirname(key));
    var current = '';
    for (final part in parts) {
      if (part == '.' || part.isEmpty) continue;
      current = current.isEmpty ? part : '$current/$part';
      if (_knownDirs.contains(current)) continue;
      final r = await _http.send(http.Request('MKCOL', _url(current))..headers.addAll(_auth));
      await r.stream.drain<void>();
      // 201 angelegt, 405 vorhanden
      if (r.statusCode != 201 && r.statusCode != 405 && r.statusCode != 301) {
        throw HttpException('WebDAV MKCOL $current: ${r.statusCode}');
      }
      _knownDirs.add(current);
    }
  }

  @override
  Future<void> upload(String key, File source) async {
    await _ensureDirs(key);
    final r = await _http.put(_url(key), headers: _auth, body: await source.readAsBytes());
    if (r.statusCode >= 300) throw HttpException('WebDAV PUT $key: ${r.statusCode}');
  }

  @override
  Future<bool> download(String key, File target) async {
    final r = await _http.send(http.Request('GET', _url(key))..headers.addAll(_auth));
    if (r.statusCode == 404) {
      await r.stream.drain<void>();
      return false;
    }
    if (r.statusCode >= 300) throw HttpException('WebDAV GET $key: ${r.statusCode}');
    await r.stream.pipe(target.openWrite());
    return true;
  }

  @override
  Future<void> remove(String key) async {
    final r = await _http.delete(_url(key), headers: _auth);
    if (r.statusCode >= 300 && r.statusCode != 404) throw HttpException('WebDAV DELETE $key: ${r.statusCode}');
  }

  Future<void> check() async {
    final r = await _http.send(http.Request('PROPFIND', baseUrl)
      ..headers.addAll({..._auth, 'depth': '0'}));
    await r.stream.drain<void>();
    if (r.statusCode == 404) {
      final mk = await _http.send(http.Request('MKCOL', baseUrl)..headers.addAll(_auth));
      await mk.stream.drain<void>();
      if (mk.statusCode != 201) throw HttpException('WebDAV-Ordner $baseUrl fehlt (${mk.statusCode})');
    } else if (r.statusCode >= 300) {
      throw HttpException('WebDAV $baseUrl nicht erreichbar: ${r.statusCode}');
    }
    _log.info('WebDAV-Speicher: $baseUrl');
  }
}
