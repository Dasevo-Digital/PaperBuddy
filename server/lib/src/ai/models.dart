import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Eine Datei eines Modells: woher, wie groß, welche Prüfsumme.
class ModelFile {
  const ModelFile(this.name, this.url, this.sha256, this.bytes);
  final String name;
  final String url;
  final String sha256;
  final int bytes;
}

/// Ein Modell aus öffentlichen Quellen. Die Gewichte liefert PaperBuddy
/// nicht mit; der Server lädt sie beim ersten Einschalten und prüft jede
/// Datei gegen ihre SHA-256.
class ModelSpec {
  const ModelSpec({required this.id, required this.source, required this.license, required this.files});

  /// Kennung, zugleich Ordnername; ändert sie sich, wird neu gerechnet.
  final String id;
  final String source;
  final String license;
  final List<ModelFile> files;

  int get bytes => files.fold(0, (s, f) => s + f.bytes);
}

/// multilingual-e5-small (Microsoft, MIT): Texte in über 90 Sprachen, auch
/// Deutsch und Englisch gemischt, als 384 Zahlen. Die ONNX-Fassung (int8,
/// 118 MB) stammt aus dem transformers.js-Projekt, fest auf einen Stand.
const e5Small = ModelSpec(
  id: 'multilingual-e5-small',
  source: 'https://huggingface.co/intfloat/multilingual-e5-small',
  license: 'MIT',
  files: [
    ModelFile(
      'model_quantized.onnx',
      'https://huggingface.co/Xenova/multilingual-e5-small/resolve/761b726dd34fb83930e26aab4e9ac3899aa1fa78/onnx/model_quantized.onnx',
      'f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193',
      118308185,
    ),
    ModelFile(
      'tokenizer.json',
      'https://huggingface.co/Xenova/multilingual-e5-small/resolve/761b726dd34fb83930e26aab4e9ac3899aa1fa78/tokenizer.json',
      '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39',
      17082730,
    ),
  ],
);

/// Ordner mit den Modellen, je Modell ein Unterordner.
class ModelStore {
  ModelStore(this.dir);
  final String dir;
  final _verified = <String>{};

  String path(ModelSpec model, String file) => p.join(dir, model.id, file);

  /// Alle Dateien da und gleich groß wie erwartet (schnell, ohne Prüfsumme).
  bool isInstalled(ModelSpec model) => model.files.every((f) {
        final file = File(path(model, f.name));
        return file.existsSync() && file.lengthSync() == f.bytes;
      });

  /// Rechnet die Prüfsummen nach, einmal je Programmlauf und Datei.
  Future<void> verify(ModelSpec model) async {
    for (final f in model.files) {
      final file = File(path(model, f.name));
      final key = '${file.path}:${file.lengthSync()}:${file.lastModifiedSync().millisecondsSinceEpoch}';
      if (_verified.contains(key)) continue;
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != f.sha256) {
        throw StateError('${file.path}: Prüfsumme $digest statt ${f.sha256}. Datei löschen, sie wird neu geladen.');
      }
      _verified.add(key);
    }
  }

  /// Lädt fehlende Dateien. [progress] bekommt die geladenen und die
  /// gesamten Bytes. Eine Datei gilt erst nach bestandener Prüfsumme.
  Future<void> download(
    ModelSpec model, {
    void Function(int done, int total)? progress,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      var done = 0;
      for (final f in model.files) {
        final target = File(path(model, f.name));
        if (target.existsSync() && target.lengthSync() == f.bytes) {
          done += f.bytes;
          progress?.call(done, model.bytes);
          continue;
        }
        target.parent.createSync(recursive: true);
        final part = File('${target.path}.part');
        final response = await c.send(http.Request('GET', Uri.parse(f.url)));
        if (response.statusCode != 200) {
          throw HttpException('${f.url}: HTTP ${response.statusCode}');
        }
        final sink = part.openWrite();
        final hashSink = _DigestSink();
        final hasher = sha256.startChunkedConversion(hashSink);
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            hasher.add(chunk);
            done += chunk.length;
            progress?.call(done, model.bytes);
          }
        } finally {
          await sink.close();
        }
        hasher.close();
        final digest = hashSink.value.toString();
        if (digest != f.sha256) {
          part.deleteSync();
          throw StateError('${f.name}: Prüfsumme $digest statt ${f.sha256}');
        }
        part.renameSync(target.path);
      }
    } finally {
      if (client == null) c.close();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Sucht `libonnxruntime`: [configured] (`PAPERBUDDY_ONNXRUNTIME`), dann
/// `lib/` neben dem Programm (Docker-Image, Server-Paket), dann übliche
/// Orte von Homebrew und Debian.
String? findOnnxRuntime(String? configured) {
  if (configured != null) return File(configured).existsSync() ? configured : null;
  final bin = File(Platform.resolvedExecutable).parent.path;
  final candidates = [
    p.join(bin, '..', 'lib', 'libonnxruntime.so'),
    p.join(bin, '..', 'lib', 'libonnxruntime.dylib'),
    if (Platform.isMacOS) ...['/opt/homebrew/lib/libonnxruntime.dylib', '/usr/local/lib/libonnxruntime.dylib'],
    if (Platform.isLinux) ...[
      '/usr/local/lib/libonnxruntime.so',
      '/usr/lib/x86_64-linux-gnu/libonnxruntime.so',
      '/usr/lib/aarch64-linux-gnu/libonnxruntime.so',
    ],
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return p.normalize(c);
  }
  return null;
}
