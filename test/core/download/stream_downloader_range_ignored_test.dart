import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

/// Covers `StreamDownloader`'s chunk loop against servers that do NOT
/// behave the way `stream_downloader_test.dart`'s `_RangeTestServer`
/// does: one that ignores `Range` outright (always 200, always the whole
/// body), one that honors it for a while and then stops, and one whose
/// `Content-Range` lies about which bytes it is actually returning. Split
/// out to keep `stream_downloader_test.dart` under this project's
/// 400-line cap.
class _RangeIgnoringServer {
  final HttpServer server;
  final Uint8List content;
  int requestCount = 0;

  _RangeIgnoringServer(this.server, this.content);

  static Future<_RangeIgnoringServer> start(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _RangeIgnoringServer(server, content);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    // Ignores any `Range` header entirely - always answers 200 with the
    // WHOLE body, exactly like a static host/CDN that does not support
    // byte-range requests at all.
    request.response.statusCode = 200;
    request.response.headers.contentLength = content.length;
    request.response.add(content);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

/// Honors `Range` correctly on the first request only, then starts
/// ignoring it (always 200, whole body) for every request after.
class _RangeThenIgnoringServer {
  final HttpServer server;
  final Uint8List content;
  int requestCount = 0;

  _RangeThenIgnoringServer(this.server, this.content);

  static Future<_RangeThenIgnoringServer> start(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _RangeThenIgnoringServer(server, content);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    final range = request.headers.value('range');
    if (requestCount == 1 && range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes $start-$end/${content.length}');
      request.response.add(content.sublist(start, end + 1));
    } else {
      request.response.statusCode = 200;
      request.response.headers.contentLength = content.length;
      request.response.add(content);
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

/// Answers every ranged request with the CORRECT byte count and the
/// CORRECT bytes for what was actually requested, but lies about it in
/// `Content-Range` (off by one) - so a check that only compares total
/// bytes written against the declared `Content-Length` at the very end
/// would never catch this; only actually validating `Content-Range`
/// itself, per chunk, does.
class _WrongContentRangeServer {
  final HttpServer server;
  final Uint8List content;

  _WrongContentRangeServer(this.server, this.content);

  static Future<_WrongContentRangeServer> start(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _WrongContentRangeServer(server, content);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';

  Future<void> _handle(HttpRequest request) async {
    final range = request.headers.value('range')!;
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    request.response.statusCode = 206;
    request.response.headers.set('Content-Range', 'bytes ${start + 1}-${end + 1}/${content.length}');
    request.response.add(content.sublist(start, end + 1));
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Uint8List content;

  setUp(() {
    content = Uint8List.fromList(List.generate(973, (i) => i % 256));
  });

  test('guard can fail: a server that ignores Range on the very first chunk is treated as the whole file, '
      'not doubled', () async {
    final server = await _RangeIgnoringServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_rangeignored_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 100);
      await downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length);

      final downloaded = await File(outputPath).readAsBytes();
      // Guard can fail (verified, see report): the pre-fix chunk loop
      // accepted 200 exactly like 206 for every chunk request and
      // appended each response, so this file came back roughly
      // content.length * ceil(content.length / chunkSize) bytes long -
      // one full copy of the source per chunk request - instead of
      // exactly content.length. Reverted immediately after confirming
      // the doubled/multiplied file.
      expect(downloaded.length, content.length);
      expect(sha256.convert(downloaded), sha256.convert(content));
      expect(server.requestCount, 1, reason: 'must stop after the first request once treated as the whole file');
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('a 200 on a LATER chunk (after the first was properly ranged) is treated as an error, not appended',
      () async {
    final server = await _RangeThenIgnoringServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_laterrange_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 100, maxRetries: 1);
      await expectLater(
        downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length),
        throwsA(isA<StreamDownloadException>()),
      );
      expect(await File('$outputPath.part').exists(), isFalse);
      expect(await File(outputPath).exists(), isFalse);
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('guard can fail: a 206 whose Content-Range start does not match the requested offset is rejected, '
      'not silently accepted', () async {
    final server = await _WrongContentRangeServer.start(content);
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_wrongrange_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      // A single chunk covering the whole file: the server's per-request
      // byte COUNT always matches what was asked for (only the claimed
      // start in Content-Range is a lie), so the total bytes written
      // still equals content.length either way - this isolates the
      // Content-Range-start check from the separate final-length check,
      // proving specifically that this check (not that one) is what
      // catches it.
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: content.length, maxRetries: 1);
      await expectLater(
        downloader.download(url: server.url, outputPath: outputPath, contentLength: content.length),
        throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('Content-Range'))),
      );
      // Guard can fail (verified, see report): removing this check made
      // this test fail (no exception thrown at all, since the total byte
      // count still matched content.length) - see the report's tail.
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('a final length shorter than the declared Content-Length is rejected rather than handed off as complete',
      () async {
    // Ask for more bytes than the server actually has: every chunk gets
    // whatever slice exists (shorter than requested near the end), so the
    // total written ends up short of the declared total.
    final server = await _RangeIgnoringServer.start(content); // 200 whole-body first chunk, still short of the lie
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_shortlen_');
    final outputPath = '${tempDir.path}/out.bin';

    try {
      final downloader = StreamDownloader(allowPrivateHosts: true, chunkSize: 100, maxRetries: 1);
      await expectLater(
        downloader.download(
          url: server.url,
          outputPath: outputPath,
          contentLength: content.length + 500, // lies: server will only ever have content.length bytes
        ),
        throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('Content-Length'))),
      );
    } finally {
      await server.close();
      await tempDir.delete(recursive: true);
    }
  });
}
