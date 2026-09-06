import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';

/// Phase 6 round 4 residual follow-up (`docs/plan-phase6-av-pairing.md`,
/// "라운드 4 판결" - "스니퍼 데드라인 no-body 서버 테스트"). Accepts the
/// connection and answers with a 200 status line, then never writes a
/// single body byte and never closes - the one shape none of
/// `mp4_track_sniffer_test.dart`'s other fixtures cover:
/// `_UnboundedServer` there sends bytes past the window (caught by the
/// *byte cap* in `_readWindow`, not the *time* deadline), and every other
/// fixture closes normally or answers with a non-2xx status right away.
/// This server sends nothing at all after its headers, so only
/// `Mp4TrackSniffer.timeout`'s own internal `Timer` (not some caller-side
/// `.timeout()`, which `sniff`'s own doc comment explains is not enough on
/// its own) can ever end the call.
///
/// Built on a raw `ServerSocket` (not `HttpServer`) so the "did the peer
/// actually close the connection" signal is a direct `onDone`/`onError` on
/// the one socket this handler owns, rather than `HttpServer`'s own
/// connection bookkeeping - which, for a response nothing was ever written
/// to or closed on the server's own initiative, does not reliably notice a
/// force-closed peer within a short test timeframe (manually confirmed:
/// `HttpServer.connectionsInfo().total` stayed 1 for seconds after the
/// client force-closed in an earlier version of this fixture).
class _NeverBodyServer {
  final ServerSocket server;
  bool sawClose = false;

  _NeverBodyServer(this.server);

  static Future<_NeverBodyServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _NeverBodyServer(server);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  void _handle(Socket socket) {
    socket.listen(
      (_) {}, // the request bytes themselves do not matter to this fixture
      onDone: () => sawClose = true,
      onError: (Object _, StackTrace __) => sawClose = true,
      cancelOnError: true,
    );
    // A minimal, valid HTTP/1.1 status line + headers, no Content-Length
    // and no body ever written after it - `Mp4TrackSniffer` only inspects
    // `response.statusCode` before starting its (never-satisfied) body
    // read, so this is enough to reach that read and then hang there.
    socket.write('HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n');
  }

  Future<void> close() => server.close();
}

void main() {
  group('Mp4TrackSniffer.sniff deadline', () {
    test(
      'a server that accepts the connection, sends headers, then never writes a body or closes '
      'is cut off by the internal deadline, not left hanging forever',
      () async {
        final server = await _NeverBodyServer.start();
        addTearDown(server.close);

        const timeout = Duration(milliseconds: 300);
        const sniffer = Mp4TrackSniffer(allowPrivateHosts: true, timeout: timeout);

        final stopwatch = Stopwatch()..start();
        final info = await sniffer.sniff(Uri.parse(server.url), const {});
        stopwatch.stop();

        expect(info, isNull);
        // Guard-can-fail (manually verified, see report): copying this file
        // aside, changing `sniff`'s `final deadlineTimer = Timer(timeout, ...)`
        // to `Timer(const Duration(days: 1), ...)` (ignoring the
        // constructor's `timeout` entirely) makes this test time out at the
        // 10-second `Timeout` above instead of completing - restored from
        // that copy immediately after, confirmed identical via `diff -q`.
        expect(
          stopwatch.elapsed,
          lessThan(timeout + const Duration(seconds: 1)),
          reason: '`sniff` must return once its own internal deadline Timer fires, not hang until some outer '
              '.timeout() eventually gives up on the Future it returned',
        );

        // `sniff`'s own `settle()` force-closes the `HttpClient` it opened
        // the moment the deadline fires - give the raw socket a moment to
        // actually observe that teardown, then confirm it happened. This
        // is also proof `sniff` tore the real connection down on timeout,
        // not merely that its own returned Future resolved while a socket
        // was left dangling on the server side.
        var attempts = 0;
        while (!server.sawClose && attempts < 20) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          attempts++;
        }
        expect(server.sawClose, isTrue, reason: 'the server must have observed the client force-close the connection');
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
