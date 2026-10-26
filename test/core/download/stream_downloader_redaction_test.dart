import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

/// Bulwark round 2: StreamDownloader's refusal messages name the host only
/// (they used to strip just the query, leaving path tokens in place). Both
/// refusals happen before any connection, so no network is touched.
void main() {
  late Directory tempDir;

  setUp(() async => tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_redact_'));
  tearDown(() async => tempDir.delete(recursive: true));

  Future<String> refusalFor(String url) async {
    try {
      await StreamDownloader().download(url: url, outputPath: '${tempDir.path}/out.bin', contentLength: 100);
    } on StreamDownloadException catch (e) {
      return e.message;
    }
    fail('expected a refusal for $url');
  }

  test('a non-https refusal keeps neither the path token nor the query', () async {
    final message = await refusalFor('http://cdn.example.invalid/ks/PATHSECRET/v.mp4?sig=QUERYSECRET');
    expect(message, contains('http://cdn.example.invalid/...'));
    expect(message, isNot(contains('PATHSECRET')));
    expect(message, isNot(contains('QUERYSECRET')));
  });

  test('a private-host refusal keeps neither userinfo nor path', () async {
    final message = await refusalFor('https://user:pw@10.0.0.5/hdnts=exp=1~hmac=PATHSECRET/seg.ts');
    expect(message, contains('https://10.0.0.5/...'));
    expect(message, isNot(contains('PATHSECRET')));
    expect(message, isNot(contains('pw@')));
  });
}
