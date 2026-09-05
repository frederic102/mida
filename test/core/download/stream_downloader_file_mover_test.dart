import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/utils/file_mover.dart';

/// Covers `StreamDownloader.download`'s final move: it goes through
/// `FileMover` (not a bare `File.rename`) specifically so a transient
/// Windows AV/indexer lock on the just-finished file - live-caught as
/// `PathAccessException` right after a large download in the coverage
/// probe - gets retried instead of crashing the whole download. Split out
/// of `stream_downloader_test.dart` to keep it under the 400-line cap.
void main() {
  test('guard can fail: a PathAccessException on the final move is retried via the injected FileMover, '
      'not left to crash the download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add('hello world'.codeUnits);
      await request.response.close();
    });
    final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_mover_');
    final outputPath = '${tempDir.path}/out.bin';
    var moveCalls = 0;

    try {
      final fileMover = FileMover(
        rename: (src, dst) async {
          moveCalls++;
          if (moveCalls < 2) {
            throw PathAccessException(dst, const OSError('Access is denied', 5), 'simulated AV lock');
          }
          return src.rename(dst);
        },
        backoff: (_) => Duration.zero,
      );
      final downloader = StreamDownloader(
        allowPrivateHosts: true,
        fileMover: fileMover,
      );
      addTearDown(downloader.close);

      await downloader.download(url: 'http://127.0.0.1:${server.port}/f', outputPath: outputPath);

      expect(moveCalls, 2, reason: 'must retry past the simulated transient lock, not give up on attempt 1');
      expect(await File(outputPath).readAsString(), 'hello world');
    } finally {
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    }
  });
}
