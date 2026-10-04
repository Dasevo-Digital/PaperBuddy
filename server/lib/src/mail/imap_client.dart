import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Verbindungsart wie in Paperless-ngx (`imap_security`).
enum ImapSecurity {
  none(1),
  ssl(2),
  startTls(3);

  const ImapSecurity(this.value);
  final int value;

  static ImapSecurity of(int? v) => values.firstWhere((s) => s.value == v, orElse: () => ssl);
}

class ImapException implements Exception {
  ImapException(this.message);
  final String message;
  @override
  String toString() => 'IMAP: $message';
}

/// Antwort auf einen Befehl: unmarkierte Zeilen samt Literalen.
class ImapResponse {
  ImapResponse(this.status, this.text, this.untagged);
  final String status;
  final String text;

  /// Jede unmarkierte Antwort als Liste aus Textteilen und Literalen.
  final List<List<Object>> untagged;
}

/// Schlanker IMAP4rev1-Client: genug zum Abholen von Anhängen.
class ImapClient {
  ImapClient._(this._socket) {
    _sub = _socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  Socket _socket;
  late StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  final _waiters = <Completer<void>>[];
  bool _closed = false;
  Object? _error;
  int _tag = 0;
  Set<String> capabilities = {};

  static const _timeout = Duration(seconds: 60);

  static Future<ImapClient> connect(String host, int port, ImapSecurity security) async {
    final Socket socket = security == ImapSecurity.ssl
        ? await SecureSocket.connect(host, port, timeout: _timeout)
        : await Socket.connect(host, port, timeout: _timeout);
    final client = ImapClient._(socket);
    final greeting = await client._readLine();
    if (!greeting.startsWith('* OK') && !greeting.startsWith('* PREAUTH')) {
      await client.close();
      throw ImapException('Unerwartete Begrüßung: $greeting');
    }
    if (security == ImapSecurity.startTls) {
      await client.command('STARTTLS');
      await client._sub.cancel();
      client._socket = await SecureSocket.secure(client._socket, host: host);
      client._sub = client._socket.listen(client._onData, onError: client._onError, onDone: client._onDone);
    }
    await client.refreshCapabilities();
    return client;
  }

  // Lesen ---------------------------------------------------------------------

  void _onData(Uint8List data) {
    _buffer.add(data);
    _wake();
  }

  void _onError(Object e) {
    _error = e;
    _wake();
  }

  void _onDone() {
    _closed = true;
    _wake();
  }

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  void _collect() {
    if (_buffer.isNotEmpty) {
      final fresh = _buffer.takeBytes();
      _pending = _pending.isEmpty ? fresh : Uint8List.fromList([..._pending, ...fresh]);
    }
  }

  Future<void> _waitForData() async {
    if (_error != null) throw ImapException('$_error');
    if (_closed) throw ImapException('Verbindung geschlossen');
    final c = Completer<void>();
    _waiters.add(c);
    await c.future.timeout(_timeout, onTimeout: () => throw ImapException('Zeitüberschreitung'));
  }

  Future<String> _readLine() async {
    while (true) {
      _collect();
      for (var i = 0; i + 1 < _pending.length; i++) {
        if (_pending[i] == 13 && _pending[i + 1] == 10) {
          final line = utf8.decode(_pending.sublist(0, i), allowMalformed: true);
          _pending = _pending.sublist(i + 2);
          return line;
        }
      }
      await _waitForData();
    }
  }

  Future<Uint8List> _readBytes(int n) async {
    while (true) {
      _collect();
      if (_pending.length >= n) {
        final out = _pending.sublist(0, n);
        _pending = _pending.sublist(n);
        return out;
      }
      await _waitForData();
    }
  }

  /// Liest eine logische Antwortzeile inklusive Literalen `{n}`.
  Future<List<Object>> _readResponse() async {
    final parts = <Object>[];
    while (true) {
      final line = await _readLine();
      final m = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (m == null) {
        parts.add(line);
        return parts;
      }
      parts.add(line.substring(0, m.start));
      parts.add(await _readBytes(int.parse(m.group(1)!)));
    }
  }

  // Befehle -------------------------------------------------------------------

  Future<ImapResponse> command(String cmd, {bool throwOnNo = true}) async {
    final tag = 'A${(++_tag).toString().padLeft(4, '0')}';
    _socket.write('$tag $cmd\r\n');
    await _socket.flush();
    final untagged = <List<Object>>[];
    while (true) {
      final parts = await _readResponse();
      final first = parts.first as String;
      if (first.startsWith('$tag ')) {
        final rest = first.substring(tag.length + 1);
        final space = rest.indexOf(' ');
        final status = space < 0 ? rest : rest.substring(0, space);
        final text = space < 0 ? '' : rest.substring(space + 1);
        if (status != 'OK' && throwOnNo) {
          throw ImapException('${cmd.split(' ').first} fehlgeschlagen: $text');
        }
        return ImapResponse(status, text, untagged);
      }
      if (first.startsWith('+')) continue; // Fortsetzung, hier nicht genutzt
      untagged.add(parts);
    }
  }

  static String quote(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  /// Ordnernamen in modifiziertem UTF-7 (RFC 3501) kodieren.
  static String encodeMailbox(String name) {
    final out = StringBuffer();
    final pending = <int>[];
    void flush() {
      if (pending.isEmpty) return;
      final bytes = <int>[];
      for (final c in pending) {
        bytes
          ..add(c >> 8)
          ..add(c & 0xff);
      }
      out.write('&${base64.encode(bytes).replaceAll('=', '').replaceAll('/', ',')}-');
      pending.clear();
    }

    for (final unit in name.codeUnits) {
      if (unit >= 0x20 && unit <= 0x7e) {
        flush();
        out.write(unit == 0x26 ? '&-' : String.fromCharCode(unit));
      } else {
        pending.add(unit);
      }
    }
    flush();
    return out.toString();
  }

  Future<void> refreshCapabilities() async {
    final r = await command('CAPABILITY');
    for (final u in r.untagged) {
      final line = u.first as String;
      if (line.startsWith('* CAPABILITY ')) {
        capabilities = line.substring(13).toUpperCase().split(' ').toSet();
      }
    }
  }

  Future<void> login(String user, String password) async {
    await command('LOGIN ${quote(user)} ${quote(password)}');
    await refreshCapabilities();
  }

  Future<List<String>> listMailboxes() async {
    final r = await command('LIST "" "*"');
    return [
      for (final u in r.untagged)
        if ((u.first as String).startsWith('* LIST'))
          _mailboxName(u),
    ];
  }

  String _mailboxName(List<Object> parts) {
    if (parts.length > 1 && parts[1] is Uint8List) return utf8.decode(parts[1] as Uint8List);
    final line = parts.first as String;
    final m = RegExp(r'\) (?:"[^"]*"|NIL) (.+)$').firstMatch(line);
    var name = m?.group(1) ?? line;
    if (name.startsWith('"') && name.endsWith('"')) name = name.substring(1, name.length - 1).replaceAll(r'\"', '"');
    return name;
  }

  Future<void> select(String mailbox) => command('SELECT ${quote(encodeMailbox(mailbox))}');

  Future<List<int>> uidSearch(String criteria) async {
    final r = await command('UID SEARCH $criteria');
    final uids = <int>[];
    for (final u in r.untagged) {
      final line = u.first as String;
      if (line.startsWith('* SEARCH')) {
        uids.addAll(line.substring(8).trim().split(' ').where((s) => s.isNotEmpty).map(int.parse));
      }
    }
    return uids;
  }

  /// Komplette Nachricht, ohne sie als gelesen zu markieren.
  Future<Uint8List?> fetchMessage(int uid) async {
    final r = await command('UID FETCH $uid (BODY.PEEK[])');
    for (final u in r.untagged) {
      for (final part in u) {
        if (part is Uint8List) return part;
      }
    }
    return null;
  }

  Future<void> addFlags(int uid, String flags) => command('UID STORE $uid +FLAGS ($flags)');

  Future<void> move(int uid, String mailbox) async {
    final target = quote(encodeMailbox(mailbox));
    if (capabilities.contains('MOVE')) {
      await command('UID MOVE $uid $target');
    } else {
      await command('UID COPY $uid $target');
      await delete(uid);
    }
  }

  Future<void> delete(int uid) async {
    await addFlags(uid, r'\Deleted');
    if (capabilities.contains('UIDPLUS')) {
      await command('UID EXPUNGE $uid');
    } else {
      await command('EXPUNGE');
    }
  }

  Future<void> logout() async {
    try {
      await command('LOGOUT', throwOnNo: false);
    } catch (_) {
      // Server schließt die Verbindung oft sofort.
    }
    await close();
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}
