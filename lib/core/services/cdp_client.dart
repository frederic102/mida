import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One decoded Chrome DevTools Protocol event frame (a message with a
/// `method` but no `id`). `sessionId` is present once a command was sent in
/// flattened `Target.attachToTarget` mode; browser-level events omit it.
class CdpEvent {
  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;

  const CdpEvent({required this.method, required this.params, this.sessionId});

  @override
  String toString() => 'CdpEvent($method, session: $sessionId, params: $params)';
}

/// Thrown when a CDP command receives an `error` reply instead of `result`.
class CdpCommandException implements Exception {
  final String method;
  final Object error;

  const CdpCommandException(this.method, this.error);

  @override
  String toString() => 'CdpCommandException($method: $error)';
}

/// Minimal JSON-RPC-over-WebSocket client for the Chrome DevTools Protocol.
/// Handles the wire format only (id-correlated command/response pairs plus
/// an unsolicited event stream); nothing here knows about `Target.*`
/// sessions, browser processes, or media semantics - that lives in
/// `browser_devtools_session.dart`. Kept separate so both halves stay under
/// the project's 400-line file cap and so this half can be exercised in
/// tests against a plain local WebSocket server, without a real browser.
class CdpClient {
  final WebSocket _socket;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _eventsController = StreamController<CdpEvent>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  int _nextId = 1;
  bool _closed = false;

  CdpClient._(this._socket) {
    _subscription = _socket.listen(_onData, onDone: _onSocketDone, onError: (_) {}, cancelOnError: false);
  }

  static Future<CdpClient> connect(Uri webSocketUrl) async {
    final socket = await WebSocket.connect(webSocketUrl.toString());
    return CdpClient._(socket);
  }

  /// All events received so far, filtered to a session with `sessionId` by
  /// callers that need one (browser-level events have none).
  Stream<CdpEvent> get events => _eventsController.stream;

  /// Sends one CDP command and waits for its correlated reply. [sessionId]
  /// must be supplied for any domain enabled on an attached target
  /// (`Network.*`, `Page.*`, `Runtime.*` in flattened mode); omit it for
  /// browser-level commands (`Target.*`, `Browser.*`).
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (_closed) {
      return Future.error(StateError('CdpClient.send($method) called after close()'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final message = <String, dynamic>{
      'id': id,
      'method': method,
      'params': params ?? const <String, dynamic>{},
      if (sessionId != null) 'sessionId': sessionId,
    };
    _socket.add(jsonEncode(message));

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('CDP command "$method" timed out after $timeout');
      },
    );
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> decoded;
    try {
      decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return; // Not valid JSON; ignore rather than crash the listener.
    }

    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = decoded['error'];
      if (error != null) {
        completer.completeError(CdpCommandException(decoded['method'] as String? ?? '<unknown>', error));
      } else {
        final result = decoded['result'];
        completer.complete(result is Map ? result.cast<String, dynamic>() : const <String, dynamic>{});
      }
      return;
    }

    final method = decoded['method'];
    if (method is! String) return;
    final params = decoded['params'];
    _eventsController.add(CdpEvent(
      method: method,
      params: params is Map ? params.cast<String, dynamic>() : const <String, dynamic>{},
      sessionId: decoded['sessionId'] as String?,
    ));
  }

  void _onSocketDone() {
    _failAllPending(StateError('CDP WebSocket closed'));
  }

  void _failAllPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAllPending(StateError('CdpClient closed'));
    await _subscription?.cancel();
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
    try {
      await _socket.close();
    } catch (_) {
      // Already closed by the peer; nothing left to do.
    }
  }
}
