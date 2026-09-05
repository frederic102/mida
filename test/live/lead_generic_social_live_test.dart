import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';

/// Lead probe: does the generic (browser-render) path already reach
/// Instagram and TikTok posts? Informational, gated by MIDA_LIVE=1.
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1';

  for (final url in [
    'https://www.instagram.com/reel/Chunk8-jurw/',
    'https://www.tiktok.com/@hankgreen1/video/7047596209028074758',
    'https://vimeo.com/76979871',
  ]) {
    test('generic probe $url', () async {
      try {
        final info = await GenericExtractor().extract(Uri.parse(url));
        stdout.writeln('OK $url title="${info.title}" formats=${info.formats.length}');
        for (final f in info.formats.take(4)) {
          stdout.writeln('   ${f.container} ${f.height} ${f.url.substring(0, f.url.length.clamp(0, 90))}');
        }
        if (info.formats.isNotEmpty) {
          final c = HttpClient();
          final r = await c.getUrl(Uri.parse(info.formats.first.url));
          info.requestHeaders.forEach(r.headers.set);
          r.headers.set('Range', 'bytes=0-1023');
          final rr = await r.close();
          await rr.drain();
          stdout.writeln('   range -> HTTP ${rr.statusCode}');
          c.close(force: true);
        }
      } catch (e) {
        stdout.writeln('FAIL $url -> $e');
      }
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));
  }
}
