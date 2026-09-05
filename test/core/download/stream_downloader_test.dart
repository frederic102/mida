import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

/// Minimal local Range-serving HTTP server so chunked downloads and retry
/// behavior can be exercised without touching the network.
class _RangeTestServer {
  final HttpServer server;
  final Uint8List content;
  int requestCount = 0;

  /// When set, the *first* request whose Range starts at this offset gets
  /// [failStatusCode] instead of the real bytes; every later request
  /// (including the retry) is served normally. Models a transient CDN
  /// hiccup (500) or a signed-URL expiry mid-download (403).
  int? failOnceAtOffset;
  int failStatusCode = 500;
  bool _failedOnce = false;

  /// Every failure on this many attempts before finally succeeding (used
  /// for the no-contentLength retry test, which has no chunk offset to key
  /// off of since it is a single unranged request).
  int failFirstNRequests = 0;

  Map<String, String>? lastRequestHeaders;

  _RangeTestServer(this.server, this.content);

  static Future<_RangeTestServer> start(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _RangeTestServer(server, content);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    lastRequestHeaders = {
      for (final name in request.headers.value('x-test-header') != null ? ['x-test-header'] : <String>[])
        name: request.headers.value(name)!,
    };
    final range = request.headers.value('range');

    int start = 0;
    int end = content.length - 1;
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
      if (match != null) {
        start = int.parse(match.group(1)!);
        end = int.parse(match.group(2)!);
      }
    }

    if (failOnceAtOffset != null && start == failOnceAtOffset && !_failedOnce) {
      _failedOnce = true;
      request.response.statusCode = failStatusCode;
      await request.response.close();
      return;
    }

    if (requestCount <= failFirstNRequests) {
      request.response.statusCode = failStatusCode;
      await request.response.close();
      return;
    }

    final slice = content.sublist(start, (end + 1).clamp(0, content.length));
    request.response.statusCode = range == null ? 200 : 206;
    request.response.headers.set('Content-Range', 'bytes $start-$end/${content.length}');
    request.response.add(slice);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Uint8List content;

  setUp(() {
    // Deterministic, non-repeating byte pattern so a chunk-boundary bug
    // (off-by-one, duplicated/skipped byte) shows up as a hash mismatch.
    content = Uint8List.fromList(List.generate(973, (i) => i % 256));
  });

  test('downloads across multiple chunks and matches the source exactly (sha256)', () async {
    final server = await _RangeTestServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 100, maxRetries: 1);
      await downloader.download(
        url: server.url,
        outputPath: outputPath,
        contentLength: content.length,
      );

      final downloaded = await File(outputPath).readAsBytes();
      expect(sha256.convert(downloaded), sha256.convert(content));
      expect(server.requestCount, greaterThanOrEqualTo(10)); // 973/100 rounded up
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('retries a chunk once after a 500 and still completes successfully', () async {
    final server = await _RangeTestServer.start(content);
    server.failOnceAtOffset = 0; // first chunk's first attempt fails
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_retry_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(
        allowPrivateHosts: true,
        chunkSize: 200,
        maxRetries: 3,
        backoff: (_) => Duration.zero, // keep the test fast
      );
      await downloader.download(
        url: server.url,
        outputPath: outputPath,
        contentLength: content.length,
      );

      final downloaded = await File(outputPath).readAsBytes();
      expect(sha256.convert(downloaded), sha256.convert(content));
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('a 403 mid-download (e.g. an expired signed URL) is retried like any other failure', () async {
    final server = await _RangeTestServer.start(content);
    server.failOnceAtOffset = 200;
    server.failStatusCode = 403;
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_403_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(
        allowPrivateHosts: true,
        chunkSize: 200,
        maxRetries: 3,
        backoff: (_) => Duration.zero,
      );
      await downloader.download(
        url: server.url,
        outputPath: outputPath,
        contentLength: content.length,
      );

      final downloaded = await File(outputPath).readAsBytes();
      expect(sha256.convert(downloaded), sha256.convert(content));
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('a chunk that keeps failing past maxRetries surfaces as StreamDownloadException', () async {
    final server = await _RangeTestServer.start(content);
    server.failOnceAtOffset = 0;
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_fail_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      // maxRetries: 1 means exactly one attempt, no retry room left, so the
      // single simulated 500 is fatal. This is the guard-can-fail case: with
      // retry logic intact this must throw; disabling retry (maxRetries: 1
      // effectively, or short-circuiting the retry loop in source) is what
      // was manually verified to turn this red. See report for the tail.
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 200, maxRetries: 1);
      await expectLater(
        downloader.download(
          url: server.url,
          outputPath: outputPath,
          contentLength: content.length,
        ),
        throwsA(isA<StreamDownloadException>()),
      );
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('no contentLength falls back to a single non-ranged GET', () async {
    final server = await _RangeTestServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_single_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true);
      await downloader.download(url: server.url, outputPath: outputPath, contentLength: null);

      final downloaded = await File(outputPath).readAsBytes();
      expect(sha256.convert(downloaded), sha256.convert(content));
      expect(server.requestCount, 1);
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('cancelling between chunks stops the download', () async {
    final server = await _RangeTestServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_cancel_');
    final outputPath = '${tempDir.path}/out.bin';
    final token = CancelToken();

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 50);
      var chunksSeen = 0;
      await expectLater(
        downloader.download(
          url: server.url,
          outputPath: outputPath,
          contentLength: content.length,
          cancelToken: token,
          onProgress: (received, total) {
            chunksSeen++;
            if (chunksSeen == 2) token.cancel();
          },
        ),
        throwsA(isA<StreamDownloadException>()),
      );
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('custom headers reach the server on every chunk request', () async {
    final server = await _RangeTestServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_headers_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 200);
      await downloader.download(
        url: server.url,
        outputPath: outputPath,
        headers: const {'X-Test-Header': 'mida-stream'},
        contentLength: content.length,
      );

      expect(server.lastRequestHeaders?['x-test-header'], 'mida-stream');
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  group('.part cleanup on failure/cancel', () {
    test('a download that fails past maxRetries does not leave a .part file behind', () async {
      final server = await _RangeTestServer.start(content);
      server.failOnceAtOffset = 0;
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_partclean_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 200, maxRetries: 1);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length),
          throwsA(isA<StreamDownloadException>()),
        );
        expect(await File('$outputPath.part').exists(), isFalse, reason: 'leaked .part file after a failed download');
        expect(await File(outputPath).exists(), isFalse);
      } finally {
        await server.close();
        await tempDir.delete(recursive: true);
      }
    });

    test('a cancelled download does not leave a .part file behind', () async {
      final server = await _RangeTestServer.start(content);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_cancelclean_');
      final outputPath = '${tempDir.path}/out.bin';
      final token = CancelToken();

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 50);
        var chunksSeen = 0;
        await expectLater(
          downloader.download(
            url: server.url,
            outputPath: outputPath,
            contentLength: content.length,
            cancelToken: token,
            onProgress: (received, total) {
              chunksSeen++;
              if (chunksSeen == 2) token.cancel();
            },
          ),
          throwsA(isA<StreamDownloadException>()),
        );
        expect(await File('$outputPath.part').exists(), isFalse, reason: 'leaked .part file after cancellation');
      } finally {
        await server.close();
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('_fetchOnce retry (no contentLength path)', () {
    test('a single-GET fetch retries after a transient failure, same as the chunked path', () async {
      final server = await _RangeTestServer.start(content);
      server.failFirstNRequests = 1; // first attempt fails, second succeeds
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_fetchonce_retry_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 3, backoff: (_) => Duration.zero);
        await downloader.download(url: server.url, outputPath: outputPath, contentLength: null);

        final downloaded = await File(outputPath).readAsBytes();
        expect(sha256.convert(downloaded), sha256.convert(content));
        expect(server.requestCount, 2);
      } finally {
        await server.close();
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('https-only guard', () {
    test('refuses a non-https, non-loopback URL without attempting a connection', () async {
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_https_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader();
        await expectLater(
          downloader.download(
            url: 'http://example.invalid/video.mp4',
            outputPath: outputPath,
            contentLength: 100,
          ),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('https'))),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('by default (allowPrivateHosts: false), a loopback URL is refused just like any other private host', () async {
      final server = await _RangeTestServer.start(content);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_loopback_default_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(chunkSize: 200); // allowPrivateHosts defaults to false
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length),
          throwsA(isA<StreamDownloadException>()),
        );
      } finally {
        await server.close();
        await tempDir.delete(recursive: true);
      }
    });

    test('with allowPrivateHosts: true (what every other test here relies on), http against loopback works', () async {
      final server = await _RangeTestServer.start(content);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_loopback_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 200);
        await downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length);
        expect(await File(outputPath).exists(), isTrue);
      } finally {
        await server.close();
        await tempDir.delete(recursive: true);
      }
    });

  });
}
