import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

import 'embedder.dart';
import 'index.dart';
import 'models.dart';
import 'onnx.dart';

final _log = Logger('ai');

/// Einstellungen der lokalen KI (`PAPERBUDDY_AI*`).
class AiSettings {
  const AiSettings({this.enabled = false, this.modelsDir = 'models', this.runtime, this.threads = 0});

  final bool enabled;

  /// Wohin die Modelle geladen werden.
  final String modelsDir;

  /// Pfad zu `libonnxruntime`; `null` = suchen (siehe [findOnnxRuntime]).
  final String? runtime;

  /// Rechenfäden; 0 = halb so viele wie Kerne.
  final int threads;
}

enum AiState { disabled, unavailable, downloading, ready, error }

/// Ein Treffer der semantischen Suche.
class SemanticHit {
  SemanticHit(this.id, this.score, this.start, this.end);
  final int id;
  final double score;

  /// Bester Abschnitt im Inhalt.
  final int start;
  final int end;
}

/// Lokale KI: lädt das Modell, berechnet im Hintergrund die Vektoren aller
/// Dokumente und beantwortet Suchanfragen.
///
/// Das Modell wird erst geladen, wenn es gebraucht wird, und nach zwei
/// Minuten ohne Arbeit wieder freigegeben (rund 300 MB Arbeitsspeicher).
class AiService {
  AiService({required this.db, required this.settings, http.Client? client, this.idle = const Duration(minutes: 2)})
      : index = VectorIndex(db),
        // ignore: prefer_initializing_formals
        _client = client,
        _embedderFactory = null;

  /// Für Tests: sofort bereit mit einem eigenen Modell.
  AiService.withEmbedder(this.db, TextEmbedder embedder, {this.idle = const Duration(minutes: 2)})
      : settings = const AiSettings(enabled: true),
        index = VectorIndex(db),
        _client = null,
        _embedderFactory = (() async => embedder) {
    index.useModel(embedder.model);
    state = AiState.ready;
  }

  final Database db;
  final AiSettings settings;
  final VectorIndex index;
  final http.Client? _client;
  final Future<TextEmbedder> Function()? _embedderFactory;
  static const model = e5Small;

  /// So lange ohne Arbeit, bis das Modell freigegeben wird.
  final Duration idle;

  AiState state = AiState.disabled;
  String? error;
  double? progress;
  String? runtimeVersion;
  bool get ready => state == AiState.ready;

  String? _runtimePath;
  OnnxRuntime? _runtime;
  Future<TextEmbedder>? _embedder;

  /// Das geladene Modell; direkt statt über [_embedder], damit ein späterer
  /// Aufruf nicht auf ein Future aus einer anderen Zone wartet.
  TextEmbedder? _loaded;
  Timer? _idleTimer;
  Timer? _pollTimer;
  Timer? _pokeTimer;
  Timer? _retryTimer;
  bool _indexing = false;
  bool _closed = false;
  final _failed = <int>{};
  late final _store = ModelStore(settings.modelsDir);

  /// Prüft Laufzeit und Modell, lädt es bei Bedarf und beginnt mit dem
  /// Einlesen. Kehrt sofort zurück.
  void start() {
    if (_embedderFactory != null) {
      _startIndexing();
      return;
    }
    if (!settings.enabled) return;
    _runtimePath = findOnnxRuntime(settings.runtime);
    if (_runtimePath == null) {
      state = AiState.unavailable;
      error = settings.runtime != null
          ? 'ONNX Runtime nicht gefunden: ${settings.runtime}'
          : 'ONNX Runtime nicht gefunden (PAPERBUDDY_ONNXRUNTIME setzen)';
      _log.warning('Lokale KI eingeschaltet, aber $error');
      return;
    }
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      if (!_store.isInstalled(model)) {
        state = AiState.downloading;
        progress = 0;
        _log.info('Lade ${model.id} (${(model.bytes / 1e6).round()} MB) nach ${settings.modelsDir} …');
        await _store.download(model, client: _client, progress: (done, total) => progress = done / total);
        _log.info('${model.id} geladen.');
      }
      await _store.verify(model);
      progress = null;
      index.useModel(model.id);
      state = AiState.ready;
      error = null;
      _log.info('Lokale KI bereit (${model.id}, ${index.count} Dokument(e) eingelesen).');
      _startIndexing();
    } catch (e) {
      if (_closed) return;
      state = AiState.error;
      error = '$e';
      _log.warning('Lokale KI nicht bereit: $e. Neuer Versuch in einer Stunde.');
      _retryTimer = Timer(const Duration(hours: 1), () => unawaited(_prepare()));
    }
  }

  void _startIndexing() {
    _pollTimer ??= Timer.periodic(const Duration(minutes: 1), (_) => _indexPending());
    poke();
  }

  /// Neue oder geänderte Dokumente bald einlesen.
  void poke() {
    if (!ready) return;
    _pokeTimer?.cancel();
    _pokeTimer = Timer(const Duration(seconds: 2), _indexPending);
  }

  Future<T> _use<T>(Future<T> Function(TextEmbedder e) action) async {
    _idleTimer?.cancel();
    final embedder = _loaded ?? (_loaded = await (_embedder ??= _openEmbedder()));
    try {
      return await action(embedder);
    } finally {
      _idleTimer?.cancel();
      _idleTimer = Timer(idle, _release);
    }
  }

  Future<TextEmbedder> _openEmbedder() async {
    final factory = _embedderFactory;
    if (factory != null) return factory();
    final runtime = _runtime ??= await OnnxRuntime.start(_runtimePath!);
    runtimeVersion = runtime.version;
    return E5Embedder.open(
      runtime,
      modelPath: _store.path(model, 'model_quantized.onnx'),
      tokenizerPath: _store.path(model, 'tokenizer.json'),
      model: model.id,
      threads: settings.threads > 0 ? settings.threads : (Platform.numberOfProcessors ~/ 2).clamp(1, 8),
    ).catchError((Object e) {
      _embedder = null;
      throw e;
    });
  }

  Future<void> _release() async {
    // Mitten im Einlesen nicht; danach stellt [_index] den Zeitgeber neu.
    if (_indexing) return;
    final e = _embedder;
    _embedder = null;
    _loaded = null;
    if (e != null) await (await e).close();
  }

  /// Liest alle Dokumente ohne Vektoren ein (läuft sonst von selbst).
  Future<void> indexPending() => _indexPending();

  Future<void> _indexPending() {
    if (!ready || _closed) return Future.value();
    return _running ??= _index().whenComplete(() => _running = null);
  }

  Future<void>? _running;

  Future<void> _index() async {
    _indexing = true;
    try {
      var done = 0;
      final sw = Stopwatch()..start();
      while (!_closed && ready) {
        final ids = index.missing(limit: 20 + _failed.length).where((id) => !_failed.contains(id)).toList();
        if (ids.isEmpty) break;
        for (final id in ids) {
          if (_closed) return;
          final row = db.select('SELECT title, content FROM documents WHERE id = ?', [id]).firstOrNull;
          if (row == null) continue;
          try {
            final passages = await _use((e) => e.passages(row['title'] as String, row['content'] as String));
            // Inzwischen geändert oder gelöscht? Dann beim nächsten Durchgang.
            final now = db.select('SELECT title, content FROM documents WHERE id = ?', [id]).firstOrNull;
            if (now == null || now['title'] != row['title'] || now['content'] != row['content']) continue;
            index.store(id, passages, passages.isEmpty ? 0 : passages.first.vector.length);
            done++;
          } catch (e) {
            _failed.add(id);
            _log.warning('Dokument #$id: Vektoren nicht berechnet: $e');
          }
        }
      }
      if (done > 0) _log.info('$done Dokument(e) für die Suche eingelesen (${sw.elapsed.inSeconds} s).');
    } finally {
      _indexing = false;
      // Nur neu stellen, wenn die Freigabe während des Einlesens ausfiel.
      // Ein Durchgang ohne Arbeit (jede Minute) darf sie nicht verschieben.
      if (_loaded != null && !(_idleTimer?.isActive ?? false)) _idleTimer = Timer(idle, _release);
    }
  }

  /// Vektor einer Suchanfrage; `null`, wenn die KI nicht bereit ist.
  Future<Float32List?> query(String text) async => ready ? _use((e) => e.query(text)) : null;

  /// Vektoren eines Dokuments, das gerade verarbeitet wird.
  Future<List<Passage>?> passages(String title, String content) async {
    if (!ready) return null;
    try {
      return await _use((e) => e.passages(title, content));
    } catch (e) {
      _log.warning('Vektoren nicht berechnet: $e');
      return null;
    }
  }

  /// Speichert die Vektoren eines neu angelegten Dokuments.
  void store(int documentId, List<Passage> passages) {
    if (!ready) return;
    index.store(documentId, passages, passages.isEmpty ? 0 : passages.first.vector.length);
  }

  /// Dokumentvektor (Mittel der Abschnitte), sofern berechnet.
  Float32List? vectorOf(int documentId) {
    final v = ready ? index.of(documentId) : null;
    return v == null || v.spans.isEmpty ? null : v.mean;
  }

  /// Alle Dokumentvektoren, sofern bereit.
  Map<int, DocVectors> get vectors => ready ? index.all() : const {};

  /// Semantische Suche unter [candidates]: alles, was höchstens [margin]
  /// unter dem besten Treffer liegt, bestes zuerst.
  ///
  /// multilingual-e5 liefert Ähnlichkeiten in einem schmalen Band (passend
  /// etwa 0,85–0,92, unpassend 0,78–0,85). Eine feste Schwelle passt darum
  /// nicht zu jeder Anfrage; der Abstand zum besten Treffer schon. Gemessen
  /// an ausgedachten Dokumenten: 0,03 findet 98 % der passenden.
  List<SemanticHit> search(Float32List query, Iterable<int> candidates, {double margin = 0.03, int limit = 100}) {
    final all = index.all();
    final hits = <SemanticHit>[];
    for (final id in candidates) {
      final v = all[id];
      if (v == null || v.spans.isEmpty) continue;
      final (score, chunk) = v.best(query);
      hits.add(SemanticHit(id, score, v.spans[chunk].$1, v.spans[chunk].$2));
    }
    if (hits.isEmpty) return hits;
    hits.sort((a, b) => b.score.compareTo(a.score));
    final floor = hits.first.score - margin;
    return hits.takeWhile((h) => h.score >= floor).take(limit).toList();
  }

  Map<String, Object?> status({bool detailed = false}) => {
        'enabled': settings.enabled,
        'state': state.name,
        'model': model.id,
        if (progress != null) 'progress': double.parse(progress!.toStringAsFixed(3)),
        if (detailed) ...{
          'indexed': ready ? index.count : 0,
          'total': db.select('SELECT COUNT(*) AS c FROM documents WHERE deleted_at IS NULL').first['c'],
          'runtime': runtimeVersion,
          'models_dir': settings.modelsDir,
          'error': error,
        },
      };

  Future<void> close() async {
    _closed = true;
    for (final t in [_idleTimer, _pollTimer, _pokeTimer, _retryTimer]) {
      t?.cancel();
    }
    final e = _embedder;
    _embedder = null;
    _loaded = null;
    if (e != null) {
      try {
        await (await e).close();
      } catch (_) {}
    }
    _runtime?.close();
    _runtime = null;
  }
}
