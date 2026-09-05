import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

void main() {
  group('StreamDownloader TLS handshake failure handling', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mida_stream_tls_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('a certificate/handshake failure surfaces a clear what/why/next message, not a raw exception, '
        'and does not exhaust retries', () async {
      // A plain (non-TLS) socket standing in for a server whose real
      // certificate this machine's trust store rejects: requesting it
      // over `https://` fails the TLS handshake itself the same way an
      // untrusted certificate does (the client never receives a valid
      // TLS ServerHello either way) - the standard, portable way to
      // trigger a real HandshakeException hermetically, without needing
      // to mint a certificate at test time.
      var connectionCount = 0;
      final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => rawServer.close());
      rawServer.listen((socket) {
        connectionCount++;
        // Garbage bytes in response to the client's TLS ClientHello (not
        // a valid TLS record at all) - makes the handshake fail promptly
        // instead of hanging forever waiting for a ServerHello that will
        // never come (which merely closing the socket with no response
        // at all was observed to do instead).
        socket.add(List<int>.filled(32, 0x00));
        socket.listen((_) {});
        unawaited(socket.close());
      });

      final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 3);
      addTearDown(downloader.close);

      await expectLater(
        downloader.download(
          url: 'https://127.0.0.1:${rawServer.port}/video.mp4',
          outputPath: '${tempDir.path}/out.bin',
        ),
        throwsA(
          isA<StreamDownloadException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('certificate your system does not trust'),
              isNot(contains('HandshakeException')), // the raw exception type must not leak into the message
            ),
          ),
        ),
      );

      // Guard can fail: a certificate failure is not transient like a
      // dropped connection or a 5xx - it must fail on the first attempt,
      // not burn all `maxRetries` (3) attempts and their backoff delays
      // for an outcome that will never change.
      expect(connectionCount, 1);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('.part file is still cleaned up after a handshake failure', () async {
      final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => rawServer.close());
      rawServer.listen((socket) {
        socket.add(List<int>.filled(32, 0x00));
        socket.listen((_) {});
        unawaited(socket.close());
      });

      final downloader = StreamDownloader(allowPrivateHosts: true);
      addTearDown(downloader.close);
      final outputPath = '${tempDir.path}/out.bin';

      await expectLater(
        downloader.download(url: 'https://127.0.0.1:${rawServer.port}/video.mp4', outputPath: outputPath),
        throwsA(isA<StreamDownloadException>()),
      );

      expect(File('$outputPath.part').existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
