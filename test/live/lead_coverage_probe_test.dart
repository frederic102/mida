import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// Lead coverage probe: how many arbitrary video sites can the registry
/// actually resolve? Resolve only (no downloads), one request per site.
/// MIDA_LIVE=1 to run.
/// Real download through the production pipeline into a temp dir, then
/// ffprobe: success only if the output has a video or audio stream.
Future<String> _downloadProbe(MediaInfo info, {bool verbose = false}) async {
  if (info.formats.isEmpty) return 'no-formats';
  final projectDir = Directory.current.path;
  final ffmpeg = '$projectDir/windows_binaries/ffmpeg.exe';
  final ffprobe = '$projectDir/windows_binaries/ffprobe.exe';
  final outDir = await Directory.systemTemp.createTemp('mida_cov_');
  try {
    final pipeline = MediaDownloadPipeline(
      merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg),
    );
    final audioOnly = !info.formats.any((f) => f.hasVideo);
    final path = await pipeline
        .download(
          info: info,
          type: audioOnly ? DownloadType.audio : DownloadType.video,
          options: audioOnly
              ? const DownloadOptions(audioFormat: AudioFormat.m4a, audioQuality: AudioQuality.best)
              : const DownloadOptions(videoQuality: VideoQuality.p480, videoFormat: VideoFormat.mp4),
          outputDir: outDir.path,
        )
        .timeout(const Duration(minutes: 3));
    final size = await File(path).length();
    // Stream kinds + the video track's dimensions + container duration, so a
    // "success" line can be compared against what the extractor claimed
    // (a truncated pull or a wrong rendition must not pass as green).
    final r = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'stream=codec_type,width,height:format=duration',
      '-of', 'json',
      path,
    ]);
    final probe = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final streams = (probe['streams'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final types = streams.map((s) => s['codec_type'] as String? ?? '').where((t) => t.isNotEmpty).toSet();
    final video = streams.where((s) => s['codec_type'] == 'video').toList();
    final dims = video.isEmpty ? '-' : '${video.first['width']}x${video.first['height']}';
    final durationText = (probe['format'] as Map<String, dynamic>?)?['duration'] as String?;
    final seconds = double.tryParse(durationText ?? '');
    final expected = info.duration?.inSeconds;
    final durationNote = seconds == null
        ? 'dur=?'
        : expected == null || expected == 0
            ? 'dur=${seconds.toStringAsFixed(0)}s'
            : 'dur=${seconds.toStringAsFixed(0)}s/${expected}s';
    if (size < 10 * 1024 || types.isEmpty) return 'DL bad size=$size streams=$types';
    final truncated = seconds != null && expected != null && expected > 0 && seconds < expected * 0.9;
    final verdict = truncated ? 'DL short' : 'DL ok';
    return '$verdict ${(size / 1024 / 1024).toStringAsFixed(1)}MB streams=${types.join('+')} $dims $durationNote';
  } catch (e) {
    final msg = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    final cap = verbose ? 1200 : 80;
    return 'DL fail ${e.runtimeType}: ${msg.substring(0, msg.length > cap ? cap : msg.length)}';
  } finally {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  }
}

Future<String> _rangeProbe(MediaInfo info) async {
  if (info.formats.isEmpty) return 'no-formats';
  final client = HttpClient();
  try {
    final f = info.formats.first;
    final r = await client.getUrl(Uri.parse(f.url));
    info.requestHeaders.forEach(r.headers.set);
    r.headers.set('Range', 'bytes=0-1023');
    final rr = await r.close().timeout(const Duration(seconds: 20));
    final type = rr.headers.value('content-type') ?? '';
    await rr.drain();
    return 'HTTP ${rr.statusCode} ${type.split(';').first}';
  } catch (e) {
    return 'ERR ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  // Verified single-video pages (docs/coverage-corpus.md + lane-verified IDs).
  const sites = <String, String>{
    'youtube': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'twitter': 'https://twitter.com/captainamerica/status/719944021058060289',
    'tiktok': 'https://www.tiktok.com/@hankgreen1/video/7047596209028074758',
    'instagram': 'https://www.instagram.com/reel/Chunk8-jurw/',
    'naver-tv': 'https://tv.naver.com/v/105228483',
    'chzzk': 'https://chzzk.naver.com/video/14834019',
    'dailymotion': 'https://www.dailymotion.com/video/x3j0j89',
    'twitch-vod': 'https://www.twitch.tv/videos/2863640137',
    'twitch-clip': 'https://clips.twitch.tv/AnimatedOptimisticWasabiVoteNay',
    'reddit': 'https://www.reddit.com/r/aww/comments/1c0xhqk/',
    'soundcloud': 'https://soundcloud.com/rick-astley-official/never-gonna-give-you-up',
    'bilibili': 'https://www.bilibili.com/video/BV1GJ411x7h7',
    'douyin': 'https://www.douyin.com/video/7318947853764676900',
    'niconico': 'https://www.nicovideo.jp/watch/sm9',
    'youku': 'https://v.youku.com/v_show/id_XNDI5ODI5NTQzNg==.html',
    'weibo-video': 'https://weibo.com/tv/show/1034:5080340418793999',
    'vk-video': 'https://vk.com/video-30558759_456239017',
    'ok-ru': 'https://ok.ru/video/14543307672246',
    'odysee': 'https://odysee.com/@lbry:3f/odysee:7',
    'rumble': 'https://rumble.com/v2r1rw6-top-7-most-viewed-videos.html',
    'bandcamp': 'https://booelectric.bandcamp.com/track/want-for-nothing',
    'pinterest': 'https://www.pinterest.com/pin/diy-pin-tutorial-video--41025046600764526/',
    'ted': 'https://www.ted.com/talks/simon_sinek_how_great_leaders_inspire_action',
    'coub': 'https://coub.com/view/3dl4uh',
    'facebook': 'https://www.facebook.com/NatGeoAnimals/videos/reindeer-national-geographic/371360365972647/',
    'tumblr': 'https://nasa.tumblr.com/post/616923388224667648',
    'bbc-news': 'https://www.bbc.co.uk/news/videos/cz7z93zde3po',
    'nytimes': 'https://www.nytimes.com/video/multimedia/100000004703252/stephen-jones-talks-top-hats.html',
    'streamable': 'https://streamable.com/moo',
    'archive-org': 'https://archive.org/details/BigBuckBunny_124',
    'vimeo-public': 'https://vimeo.com/22439234',
    'w3schools-mp4': 'https://www.w3schools.com/html/mov_bbb.mp4',
  };

  // Lead diagnosis knobs: MIDA_SITES=a,b,c limits the run to those keys
  // (default gate = 0 when set, so a partial run never fails on the
  // full-corpus floor), MIDA_VERBOSE=1 prints every resolved format plus
  // the untruncated pipeline error - for reproducing one site's failure
  // without re-hitting the other 31.
  final only = (Platform.environment['MIDA_SITES'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  final selected = only.isEmpty ? sites : {for (final e in sites.entries) if (only.contains(e.key)) e.key: e.value};
  final verbose = Platform.environment['MIDA_VERBOSE'] == '1';

  test('coverage probe across arbitrary video sites', () async {
    final registry = buildExtractorRegistry();
    var ok = 0;
    final results = <String>[];
    for (final e in selected.entries) {
      final sw = Stopwatch()..start();
      try {
        final info = await registry
            .resolveInfo(Uri.parse(e.value))
            .timeout(const Duration(seconds: 90));
        if (verbose) {
          for (final f in info.formats) {
            final u = f.url.length > 600 ? '${f.url.substring(0, 600)}...' : f.url;
            stdout.writeln('  [${e.key}] fmt id=${f.id.length > 60 ? '${f.id.substring(0, 60)}...' : f.id} '
                'proto=${f.protocol} cont=${f.container} v=${f.hasVideo} a=${f.hasAudio} '
                'h=${f.height} br=${f.bitrate} len=${f.contentLength} capsUnknown=${f.capabilitiesUnknown} url=$u');
          }
        }
        final range = await _rangeProbe(info);
        final probe = range.startsWith('HTTP 2') ? await _downloadProbe(info, verbose: verbose) : range;
        if (probe.startsWith('DL ok')) ok++;
        final heights = info.formats.map((f) => f.height).whereType<int>().toSet().toList()..sort();
        results.add('OK   ${e.key.padRight(16)} formats=${info.formats.length} heights=$heights '
            'range=$probe ${sw.elapsed.inSeconds}s title="${info.title.length > 40 ? '${info.title.substring(0, 40)}...' : info.title}"');
      } on MediaExtractionException catch (ex) {
        results.add('FAIL ${e.key.padRight(16)} ${ex.status} ${sw.elapsed.inSeconds}s'
            '${verbose ? ' ${ex.toString().replaceAll(RegExp(r'\s+'), ' ')}' : ''}');
      } catch (ex) {
        results.add('ERR  ${e.key.padRight(16)} ${ex.runtimeType} ${sw.elapsed.inSeconds}s'
            '${verbose ? ' ${ex.toString().replaceAll(RegExp(r'\s+'), ' ')}' : ''}');
      }
    }
    for (final r in results) {
      stdout.writeln(r);
    }
    stdout.writeln('COVERAGE (resolve + pipeline download + ffprobe): $ok / ${selected.length}');
    final minOk = int.tryParse(Platform.environment['MIDA_COVERAGE_MIN'] ?? '') ?? (only.isEmpty ? 16 : 0);
    expect(ok, greaterThanOrEqualTo(minOk), reason: 'coverage below MIDA_COVERAGE_MIN=$minOk');
  }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 120)));
}
