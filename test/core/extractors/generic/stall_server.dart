import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Raw-socket loopback server for deadline tests. For each connection it
/// records the request line plus `Host` header once the request head has
/// arrived, immediately writes [head] (raw bytes, e.g. a status line and
/// headers promising a body that never comes), then holds the connection
/// open. [releaseAll] writes [release] to every connection a client still
/// holds and closes it: a response that arrives "late", at a moment the test
/// chooses (deterministic even on a starved machine, unlike a timer).
/// [closedByClient] completes per connection when the client hangs up,
/// which is how a test proves a connection was actually torn down rather
/// than merely given up on.
class StallServer {
  final ServerSocket _server;
  final String? head;
  final String release;
  final List<Socket> _open = [];
  final List<String> requests = [];
  final List<Completer<void>> closedByClient = [];

  StallServer._(this._server, this.head, this.release);

  static Future<StallServer> start({String? head, String release = ''}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final stall = StallServer._(server, head, release);
    server.listen(stall._onSocket);
    return stall;
  }

  int get port => _server.port;

  void _onSocket(Socket socket) {
    final closed = Completer<void>();
    closedByClient.add(closed);
    _open.add(socket);
    var seenHead = false;
    final buffer = StringBuffer();

    void markClosed() {
      _open.remove(socket);
      if (!closed.isCompleted) closed.complete();
    }

    socket.done.then((_) {}, onError: (Object _) {});
    socket.listen(
      (data) {
        if (seenHead) return;
        buffer.write(latin1.decode(data));
        final text = buffer.toString();
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        seenHead = true;
        final host = RegExp(r'^host:\s*(\S+)', multiLine: true, caseSensitive: false).firstMatch(text)?.group(1);
        requests.add('${text.substring(0, text.indexOf('\r\n'))} @$host');
        if (head != null) socket.add(latin1.encode(head!));
      },
      onDone: () {
        markClosed();
        socket.destroy();
      },
      onError: (Object _) => markClosed(),
    );
  }

  /// Answers every connection still open with [release], then closes it.
  void releaseAll() {
    for (final socket in _open.toList()) {
      socket.add(latin1.encode(release));
      socket.close().then((_) {}, onError: (Object _) {});
    }
  }

  /// A client whose every connection, whatever the URL, lands here.
  HttpClient client() => HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, port);

  Future<void> close() => _server.close();
}
