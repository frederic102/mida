import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

/// Covers `StreamDownloader`'s `https`-path Content-Type rejection: a
/// candidate whose "media" URL actually resolves to an HTML/JSON error
/// body must be refused (candidate failure) rather than saved as if it
/// were the real download - live-caught (coordinator repro, coverage
/// probe): a 1.7MB file with zero real streams per ffprobe.
Future<HttpServer> _serverReturning(String contentType, List<int> body, {bool ranged = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.set('content-type', contentType);
    if (ranged && request.headers.value('range') != null) {
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes 0-${body.length - 1}/${body.length}');
    }
    request.response.add(body);
    await request.response.close();
  });
  return server;
}

void main() {
  final errorBody = Uint8List.fromList('{"error":"not found"}'.codeUnits);

  group('unranged (_fetchOnce) path', () {
    test('guard can fail: an application/json body is refused, not saved as if it were the download', () async {
      final server = await _serverReturning('application/json', errorBody);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_ct_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('Content-Type'))),
        );
        expect(await File(outputPath).exists(), isFalse);
        expect(await File('$outputPath.part').exists(), isFalse);
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });

    test('guard can fail: a text/html body is refused too', () async {
      final server = await _serverReturning('text/html; charset=utf-8', '<html>404</html>'.codeUnits);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_ct_html_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('Content-Type'))),
        );
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });

    test('a real video/mp4 body still downloads normally', () async {
      final body = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final server = await _serverReturning('video/mp4', body);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_ct_ok_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true);
        await downloader.download(url: server.url, outputPath: outputPath);
        expect(await File(outputPath).readAsBytes(), body);
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });

    test('a missing Content-Type is not itself refused', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.removeAll('content-type');
        request.response.add('plain bytes, no content-type at all'.codeUnits);
        await request.response.close();
      });
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_ct_none_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true);
        await downloader.download(url: 'http://127.0.0.1:${server.port}/f', outputPath: outputPath);
        expect(await File(outputPath).exists(), isTrue);
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('body-prefix rejection (Content-Type alone does not catch a mislabeled body)', () {
    test('guard can fail: a body starting with "<" is refused even when Content-Type claims video/mp4', () async {
      final server = await _serverReturning('video/mp4', '<html><body>404</body></html>'.codeUnits);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_prefix_html_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('HTML/JSON'))),
        );
        expect(await File(outputPath).exists(), isFalse);
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });

    test('guard can fail: a body starting with "#EXTM3U" is refused (an HLS playlist fetched as a plain file)',
        () async {
      final server = await _serverReturning('video/mp4', '#EXTM3U\n#EXTINF:10,\nseg1.ts\n'.codeUnits);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_prefix_m3u8_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('HTML/JSON'))),
        );
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });

    test('a real binary body that merely happens to contain "<" or "{" later on is not refused (only the '
        'leading bytes are checked)', () async {
      final body = Uint8List.fromList([0x00, 0x00, 0x00, 0x18, ...'ftypmp42'.codeUnits, 0x3C, 0x7B, 0xFF, 0xFE]);
      final server = await _serverReturning('video/mp4', body);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_prefix_binary_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true);
        await downloader.download(url: server.url, outputPath: outputPath);
        expect(await File(outputPath).readAsBytes(), body);
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('ranged (chunked) path', () {
    test('guard can fail: an application/json body on the first (ranged) chunk is refused', () async {
      final server = await _serverReturning('application/json', errorBody, ranged: true);
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_ct_ranged_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1, chunkSize: 100);
        await expectLater(
          downloader.download(url: server.url, outputPath: outputPath, contentLength: errorBody.length),
          throwsA(isA<StreamDownloadException>().having((e) => e.message, 'message', contains('Content-Type'))),
        );
      } finally {
        await server.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });
  });
}

extension on HttpServer {
  String get url => 'http://127.0.0.1:$port/f';
}
