import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// ONNX Runtime über ihre C-Schnittstelle (`dart:ffi`), ohne generierte
/// Bindungen: Die Funktionen stehen an festen Stellen der Tabelle `OrtApi`,
/// die bei neuen Fassungen nur hinten wächst.
///
/// Alle Aufrufe laufen nacheinander in einem eigenen Isolate. Ein Modell
/// rechnet blockierend; im Isolate des Servers hielte es jede Anfrage an.
class OnnxRuntime {
  OnnxRuntime._(this._to, this._from, this.version);

  final SendPort _to;
  final ReceivePort _from;

  /// Fassung der geladenen Bibliothek, etwa „1.28.3“.
  final String version;

  final _pending = <int, Completer<Object?>>{};
  var _next = 0;

  /// Lädt die Bibliothek unter [libraryPath] in einem neuen Isolate.
  static Future<OnnxRuntime> start(String libraryPath) async {
    final from = ReceivePort();
    await Isolate.spawn(_work, [from.sendPort, libraryPath], debugName: 'onnxruntime');
    final hello = Completer<List<Object?>>();
    late OnnxRuntime runtime;
    from.listen((message) {
      final m = (message as List).cast<Object?>();
      if (!hello.isCompleted) {
        hello.complete(m);
      } else {
        runtime._answer(m);
      }
    });
    final h = await hello.future;
    if (h[0] == null) {
      from.close();
      throw StateError('ONNX Runtime unter $libraryPath nicht ladbar: ${h[1]}');
    }
    return runtime = OnnxRuntime._(h[0]! as SendPort, from, h[1]! as String);
  }

  void _answer(List<Object?> m) {
    final c = _pending.remove(m[0]! as int);
    if (c == null) return;
    if (m.length > 2) {
      c.completeError(StateError(m[2]! as String));
    } else {
      c.complete(m[1]);
    }
  }

  Future<T> _ask<T>(String method, [List<Object?> args = const []]) {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _to.send([id, method, ...args]);
    return c.future.then((v) => v as T);
  }

  /// Öffnet ein Modell; [threads] begrenzt die Rechenfäden (0 = alle Kerne),
  /// [config] sind Einträge wie `session.disable_prepacking`.
  Future<OnnxSession> open(String modelPath, {int threads = 0, Map<String, String> config = const {}}) async {
    final r = await _ask<List<Object?>>('open', [modelPath, threads, config]);
    return OnnxSession._(this, r[0]! as int, (r[1]! as List).cast<String>(), (r[2]! as List).cast<String>());
  }

  /// Beendet das Isolate; offene Sitzungen gehen mit.
  void close() {
    _to.send(null);
    _from.close();
    for (final c in _pending.values) {
      c.completeError(StateError('ONNX Runtime beendet'));
    }
    _pending.clear();
  }
}

/// Ein geöffnetes Modell.
class OnnxSession {
  OnnxSession._(this._runtime, this._id, this.inputs, this.outputs);
  final OnnxRuntime _runtime;
  final int _id;
  final List<String> inputs;
  final List<String> outputs;

  /// Rechnet mit ganzzahligen Eingaben (int64) und liefert die Ausgabe
  /// [output] als float32 samt Form.
  Future<(Float32List, List<int>)> run(Map<String, (Int64List, List<int>)> feeds, String output) async {
    final r = await _runtime._ask<List<Object?>>('run', [
      _id,
      {
        for (final e in feeds.entries)
          e.key: [TransferableTypedData.fromList([e.value.$1]), e.value.$2],
      },
      output,
    ]);
    return ((r[0]! as TransferableTypedData).materialize().asFloat32List(), (r[1]! as List).cast<int>());
  }

  Future<void> close() => _runtime._ask<void>('close', [_id]);
}

// ---------------------------------------------------------------------------
// Das Isolate

void _work(List<Object?> start) {
  final reply = start[0]! as SendPort;
  final _Ort ort;
  try {
    ort = _Ort(start[1]! as String);
  } on Object catch (e) {
    reply.send([null, '$e']);
    return;
  }
  final inbox = ReceivePort();
  reply.send([inbox.sendPort, ort.version]);
  inbox.listen((message) {
    if (message == null) {
      ort.dispose();
      inbox.close();
      return;
    }
    final m = (message as List).cast<Object?>();
    final id = m[0]! as int;
    try {
      reply.send([id, ort.call(m[1]! as String, m.sublist(2))]);
    } on Object catch (e) {
      reply.send([id, null, '$e']);
    }
  });
}

/// Stellen der Funktionen in `OrtApi` (gegen `onnxruntime_c_api.h` 1.28.3
/// ausgezählt; seit 1.16 unverändert).
abstract final class _At {
  static const getErrorMessage = 2;
  static const createEnv = 3;
  static const createSession = 7;
  static const run = 9;
  static const createSessionOptions = 10;
  static const disableCpuMemArena = 19;
  static const setIntraOpNumThreads = 24;
  static const setInterOpNumThreads = 25;
  static const sessionGetInputCount = 30;
  static const sessionGetOutputCount = 31;
  static const sessionGetInputName = 36;
  static const sessionGetOutputName = 37;
  static const createTensorAsOrtValue = 48;
  static const getTensorMutableData = 51;
  static const getTensorElementType = 60;
  static const getDimensionsCount = 61;
  static const getDimensions = 62;
  static const getTensorShapeElementCount = 64;
  static const getTensorTypeAndShape = 65;
  static const allocatorFree = 76;
  static const getAllocatorWithDefaultOptions = 78;
  static const releaseEnv = 92;
  static const releaseStatus = 93;
  static const releaseSession = 95;
  static const releaseValue = 96;
  static const releaseTensorTypeAndShapeInfo = 99;
  static const releaseSessionOptions = 100;
  static const addSessionConfigEntry = 130;
}

/// Mindestens verlangte API-Fassung: alles hier gibt es seit 1.16, so
/// genügt auch eine ältere Bibliothek aus dem System.
const _apiVersion = 16;
const _float32 = 1;
const _int64 = 7;

typedef _P = Pointer<Void>;
typedef _S = Pointer<Void>; // OrtStatus*, null = gut

class _Session {
  _Session(this.pointer, this.inputs, this.outputs);
  final _P pointer;
  final List<String> inputs;
  final List<String> outputs;
}

class _Ort {
  _Ort(String path) : _lib = DynamicLibrary.open(path) {
    final base = _lib.lookupFunction<Pointer<Pointer<Void>> Function(), Pointer<Pointer<Void>> Function()>(
      'OrtGetApiBase',
    )();
    final getApi = base[0]
        .cast<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>>()
        .asFunction<Pointer<Pointer<Void>> Function(int)>();
    _api = getApi(_apiVersion);
    if (_api == nullptr) throw StateError('Die Bibliothek kennt die API-Fassung $_apiVersion nicht');
    version = base[1].cast<NativeFunction<Pointer<Utf8> Function()>>().asFunction<Pointer<Utf8> Function()>()().toDartString();
    _bind();
    _env = using((a) {
      final out = a<_P>();
      // Nur Fehler melden: Beim Laden kämen sonst viele Warnungen ins Journal.
      _check(_createEnv(3, 'PaperBuddy'.toNativeUtf8(allocator: a), out));
      return out.value;
    });
    _allocator = using((a) {
      final out = a<_P>();
      _check(_getAllocator(out));
      return out.value;
    });
  }

  final DynamicLibrary _lib;
  late final Pointer<Pointer<Void>> _api;
  late final String version;
  late final _P _env;
  late final _P _allocator;
  final _sessions = <int, _Session>{};
  var _counter = 0;

  Pointer<NativeFunction<T>> _f<T extends Function>(int at) => _api[at].cast<NativeFunction<T>>();

  late final Pointer<Utf8> Function(_S) _errorMessage;
  late final void Function(_S) _releaseStatus;
  late final _S Function(int, Pointer<Utf8>, Pointer<_P>) _createEnv;
  late final void Function(_P) _releaseEnv;
  late final _S Function(Pointer<_P>) _getAllocator;
  late final _S Function(_P, _P) _allocatorFree;
  late final _S Function(Pointer<_P>) _createOptions;
  late final void Function(_P) _releaseOptions;
  late final _S Function(_P, int) _setIntra;
  late final _S Function(_P, int) _setInter;
  late final _S Function(_P) _disableArena;
  late final _S Function(_P, Pointer<Utf8>, Pointer<Utf8>) _addConfig;
  late final _S Function(_P, Pointer<Utf8>, _P, Pointer<_P>) _createSession;
  late final void Function(_P) _releaseSession;
  late final _S Function(_P, Pointer<Size>) _inputCount;
  late final _S Function(_P, Pointer<Size>) _outputCount;
  late final _S Function(_P, int, _P, Pointer<Pointer<Utf8>>) _inputName;
  late final _S Function(_P, int, _P, Pointer<Pointer<Utf8>>) _outputName;
  late final _S Function(_P, Pointer<Int64>, int, int, Pointer<_P>) _createTensor;
  late final _S Function(_P, Pointer<_P>) _mutableData;
  late final void Function(_P) _releaseValue;
  late final _S Function(_P, Pointer<_P>) _typeAndShape;
  late final _S Function(_P, Pointer<Int32>) _elementType;
  late final _S Function(_P, Pointer<Size>) _dimensionsCount;
  late final _S Function(_P, Pointer<Int64>, int) _dimensions;
  late final _S Function(_P, Pointer<Size>) _elementCount;
  late final void Function(_P) _releaseTypeAndShape;
  late final _S Function(_P, _P, Pointer<Pointer<Utf8>>, Pointer<_P>, int, Pointer<Pointer<Utf8>>, int, Pointer<_P>) _run;

  void _bind() {
    _errorMessage = _f<Pointer<Utf8> Function(_S)>(_At.getErrorMessage).asFunction();
    _releaseStatus = _f<Void Function(_S)>(_At.releaseStatus).asFunction();
    _createEnv = _f<_S Function(Int32, Pointer<Utf8>, Pointer<_P>)>(_At.createEnv).asFunction();
    _releaseEnv = _f<Void Function(_P)>(_At.releaseEnv).asFunction();
    _getAllocator = _f<_S Function(Pointer<_P>)>(_At.getAllocatorWithDefaultOptions).asFunction();
    _allocatorFree = _f<_S Function(_P, _P)>(_At.allocatorFree).asFunction();
    _createOptions = _f<_S Function(Pointer<_P>)>(_At.createSessionOptions).asFunction();
    _releaseOptions = _f<Void Function(_P)>(_At.releaseSessionOptions).asFunction();
    _setIntra = _f<_S Function(_P, Int32)>(_At.setIntraOpNumThreads).asFunction();
    _setInter = _f<_S Function(_P, Int32)>(_At.setInterOpNumThreads).asFunction();
    _disableArena = _f<_S Function(_P)>(_At.disableCpuMemArena).asFunction();
    _addConfig = _f<_S Function(_P, Pointer<Utf8>, Pointer<Utf8>)>(_At.addSessionConfigEntry).asFunction();
    _createSession = _f<_S Function(_P, Pointer<Utf8>, _P, Pointer<_P>)>(_At.createSession).asFunction();
    _releaseSession = _f<Void Function(_P)>(_At.releaseSession).asFunction();
    _inputCount = _f<_S Function(_P, Pointer<Size>)>(_At.sessionGetInputCount).asFunction();
    _outputCount = _f<_S Function(_P, Pointer<Size>)>(_At.sessionGetOutputCount).asFunction();
    _inputName = _f<_S Function(_P, Size, _P, Pointer<Pointer<Utf8>>)>(_At.sessionGetInputName).asFunction();
    _outputName = _f<_S Function(_P, Size, _P, Pointer<Pointer<Utf8>>)>(_At.sessionGetOutputName).asFunction();
    _createTensor = _f<_S Function(_P, Pointer<Int64>, Size, Int32, Pointer<_P>)>(_At.createTensorAsOrtValue).asFunction();
    _mutableData = _f<_S Function(_P, Pointer<_P>)>(_At.getTensorMutableData).asFunction();
    _releaseValue = _f<Void Function(_P)>(_At.releaseValue).asFunction();
    _typeAndShape = _f<_S Function(_P, Pointer<_P>)>(_At.getTensorTypeAndShape).asFunction();
    _elementType = _f<_S Function(_P, Pointer<Int32>)>(_At.getTensorElementType).asFunction();
    _dimensionsCount = _f<_S Function(_P, Pointer<Size>)>(_At.getDimensionsCount).asFunction();
    _dimensions = _f<_S Function(_P, Pointer<Int64>, Size)>(_At.getDimensions).asFunction();
    _elementCount = _f<_S Function(_P, Pointer<Size>)>(_At.getTensorShapeElementCount).asFunction();
    _releaseTypeAndShape = _f<Void Function(_P)>(_At.releaseTensorTypeAndShapeInfo).asFunction();
    _run = _f<
            _S Function(_P, _P, Pointer<Pointer<Utf8>>, Pointer<_P>, Size, Pointer<Pointer<Utf8>>, Size, Pointer<_P>)>(_At.run)
        .asFunction();
  }

  /// Ein Status ungleich null ist ein Fehler: Text holen, freigeben, werfen.
  void _check(_S status) {
    if (status == nullptr) return;
    final text = _errorMessage(status).toDartString();
    _releaseStatus(status);
    throw StateError(text);
  }

  Object? call(String method, List<Object?> a) => switch (method) {
        'open' => _open(a[0]! as String, a[1]! as int, (a[2]! as Map).cast<String, String>()),
        'run' => _run1(a[0]! as int, (a[1]! as Map).cast<String, List<Object?>>(), a[2]! as String),
        'close' => _close(a[0]! as int),
        _ => throw UnsupportedError(method),
      };

  List<Object?> _open(String path, int threads, Map<String, String> config) => using((a) {
        final out = a<_P>();
        _check(_createOptions(out));
        final options = out.value;
        try {
          if (threads > 0) _check(_setIntra(options, threads));
          _check(_setInter(options, 1));
          // Ohne Arena gibt die Laufzeit Speicher nach jeder Rechnung zurück;
          // der Server läuft lange, das Modell rechnet selten.
          _check(_disableArena(options));
          for (final MapEntry(:key, :value) in config.entries) {
            _check(_addConfig(options, key.toNativeUtf8(allocator: a), value.toNativeUtf8(allocator: a)));
          }
          final session = a<_P>();
          _check(_createSession(_env, path.toNativeUtf8(allocator: a), options, session));
          final inputs = _names(session.value, _inputCount, _inputName, a);
          final outputs = _names(session.value, _outputCount, _outputName, a);
          final id = _counter++;
          _sessions[id] = _Session(session.value, inputs, outputs);
          return [id, inputs, outputs];
        } finally {
          _releaseOptions(options);
        }
      });

  List<String> _names(
    _P session,
    _S Function(_P, Pointer<Size>) count,
    _S Function(_P, int, _P, Pointer<Pointer<Utf8>>) name,
    Arena a,
  ) {
    final n = a<Size>();
    _check(count(session, n));
    final names = <String>[];
    for (var i = 0; i < n.value; i++) {
      final p = a<Pointer<Utf8>>();
      _check(name(session, i, _allocator, p));
      names.add(p.value.toDartString());
      _check(_allocatorFree(_allocator, p.value.cast()));
    }
    return names;
  }

  _P _tensor(int type, Uint8List bytes, List<int> shape, Arena a) {
    final dims = a<Int64>(shape.length);
    for (var i = 0; i < shape.length; i++) {
      dims[i] = shape[i];
    }
    final out = a<_P>();
    _check(_createTensor(_allocator, dims, shape.length, type, out));
    try {
      final data = a<_P>();
      _check(_mutableData(out.value, data));
      data.value.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    } catch (_) {
      _releaseValue(out.value);
      rethrow;
    }
    return out.value;
  }

  List<Object?> _run1(int sessionId, Map<String, List<Object?>> feeds, String output) {
    final s = _sessions[sessionId] ?? (throw StateError('Sitzung $sessionId gibt es nicht'));
    return using((a) {
      final values = <_P>[];
      try {
        final names = a<Pointer<Utf8>>(feeds.length);
        final inputs = a<_P>(feeds.length);
        var i = 0;
        for (final e in feeds.entries) {
          final bytes = (e.value[0]! as TransferableTypedData).materialize().asUint8List();
          final shape = (e.value[1]! as List).cast<int>();
          if (bytes.length != shape.fold(8, (x, y) => x * y)) {
            throw ArgumentError('${e.key}: ${bytes.length} Bytes passen nicht zur Form $shape');
          }
          final v = _tensor(_int64, bytes, shape, a);
          values.add(v);
          names[i] = e.key.toNativeUtf8(allocator: a);
          inputs[i] = v;
          i++;
        }
        final outName = a<Pointer<Utf8>>()..value = output.toNativeUtf8(allocator: a);
        final out = a<_P>()..value = nullptr;
        _check(_run(s.pointer, nullptr, names, inputs, feeds.length, outName, 1, out));
        values.add(out.value);
        return _read(out.value, a);
      } finally {
        values.forEach(_releaseValue);
      }
    });
  }

  /// Daten (float32) und Form eines Ergebnisses.
  List<Object?> _read(_P value, Arena a) {
    final info = a<_P>();
    _check(_typeAndShape(value, info));
    final List<int> shape;
    final int count;
    try {
      final type = a<Int32>();
      _check(_elementType(info.value, type));
      if (type.value != _float32) throw StateError('Ausgabe vom Typ ${type.value} statt float32');
      final n = a<Size>();
      _check(_dimensionsCount(info.value, n));
      final dims = a<Int64>(n.value == 0 ? 1 : n.value);
      _check(_dimensions(info.value, dims, n.value));
      shape = [for (var i = 0; i < n.value; i++) dims[i]];
      final c = a<Size>();
      _check(_elementCount(info.value, c));
      count = c.value;
    } finally {
      _releaseTypeAndShape(info.value);
    }
    final data = a<_P>();
    _check(_mutableData(value, data));
    final copy = Float32List.fromList(data.value.cast<Float>().asTypedList(count));
    return [TransferableTypedData.fromList([copy]), shape];
  }

  Object? _close(int id) {
    final s = _sessions.remove(id);
    if (s != null) _releaseSession(s.pointer);
    return null;
  }

  void dispose() {
    for (final id in _sessions.keys.toList()) {
      _close(id);
    }
    _releaseEnv(_env);
  }
}
