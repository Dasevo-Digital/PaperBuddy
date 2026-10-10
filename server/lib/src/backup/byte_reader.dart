import 'dart:async';
import 'dart:typed_data';

/// Liest aus einem Byte-Stream genau so viel wie gebraucht: feste Längen,
/// Zeilen, und ob danach noch etwas kommt.
class ByteReader {
  ByteReader(Stream<List<int>> input) : _input = StreamIterator(input);

  final StreamIterator<List<int>> _input;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _done = false;

  int get _available => _buffer.length - _offset;

  /// Holt den nächsten Teil des Streams in den Puffer; `false` am Ende.
  Future<bool> _fill() async {
    if (_done) return false;
    if (!await _input.moveNext()) {
      _done = true;
      return false;
    }
    final next = _input.current;
    final merged = Uint8List(_available + next.length)
      ..setRange(0, _available, _buffer, _offset)
      ..setRange(_available, _available + next.length, next);
    _buffer = merged;
    _offset = 0;
    return true;
  }

  /// Genau [n] Bytes; mit [allowShort] am Ende auch weniger.
  Future<Uint8List> read(int n, {bool allowShort = false}) async {
    while (_available < n) {
      if (!await _fill()) {
        if (!allowShort) throw StateError('Unerwartetes Ende der Daten');
        break;
      }
    }
    final take = _available < n ? _available : n;
    final out = Uint8List.sublistView(_buffer, _offset, _offset + take);
    _offset += take;
    return Uint8List.fromList(out);
  }

  /// Gibt [n] Bytes stückweise an [sink] weiter, ohne sie ganz zu puffern.
  Future<void> forward(int n, FutureOr<void> Function(Uint8List chunk) sink) async {
    var left = n;
    while (left > 0) {
      if (_available == 0 && !await _fill()) throw StateError('Unerwartetes Ende der Daten');
      final take = _available < left ? _available : left;
      await sink(Uint8List.sublistView(_buffer, _offset, _offset + take));
      _offset += take;
      left -= take;
    }
  }

  /// Eine Zeile ohne `\n` (höchstens [maxLength] Zeichen); `null` am Ende.
  Future<String?> readLine({int maxLength = 4096}) async {
    while (true) {
      final end = _buffer.indexOf(10, _offset);
      if (end >= 0) {
        final line = String.fromCharCodes(_buffer, _offset, end);
        _offset = end + 1;
        return line;
      }
      if (_available > maxLength) throw const FormatException('Zeile zu lang');
      if (!await _fill()) return null;
    }
  }

  /// `true`, wenn keine Daten mehr folgen.
  Future<bool> atEnd() async => _available == 0 && !await _fill();

  Future<void> cancel() => _input.cancel();
}
