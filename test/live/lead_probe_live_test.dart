import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';

/// Lead diagnostic probe (MIDA_LIVE=1): print every format of a URL and the
/// real byte length + duration of the first three, to catch mislabeled or
/// truncated renditions.
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final url = Platform.environment['MIDA_PROBE_URL'] ?? 'https://www.instagram.com/reel/Chunk8-jurw/';
  final ffprobe = '${Directory.current.path}/windows_binaries/ffprobe.exe';

  test('probe $url', () async {
    final info = await buildExtractorRegistry().resolveInfo(Uri.parse(url));
    stdout.writeln('title=${info.title} duration=${info.duration} formats=${info.formats.length} headers=${info.requestHeaders.keys.toList()}');
    for (final f in info.formats) {
      stdout.writeln('  id=${f.id} ${f.container} ${f.width}x${f.height} v=${f.hasVideo}/${f.videoCodec} a=${f.hasAudio}/${f.audioCodec} br=${f.bitrate} len=${f.contentLength} proto=${f.protocol} url=...${f.url.substring((f.url.length - 70).clamp(0, f.url.length))}');
    }
    final client = HttpClient();
    for (final f in info.formats.take(3)) {
      final r = await client.getUrl(Uri.parse(f.url));
      info.requestHeaders.forEach(r.headers.set);
      final rr = await r.close();
      final tmp = File('${Directory.systemTemp.path}/mida_probe_${f.id}.bin');
      final sink = tmp.openWrite();
      await rr.pipe(sink);
      final len = await tmp.length();
      final p = await Process.run(ffprobe, ['-v', 'error', '-show_entries', 'stream=codec_type,codec_name,width,height:format=duration', '-of', 'csv=p=0', tmp.path]);
      stdout.writeln('  GET ${f.id} -> HTTP ${rr.statusCode} bytes=$len ffprobe=${(p.stdout as String).trim().replaceAll('\n', ' | ')}');
      await tmp.delete();
    }
    client.close(force: true);
  }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 4)));
}
