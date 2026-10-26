import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_sites.dart';
import 'package:mida/cli/cli_stream_probe.dart';
import 'package:mida/cli/mida_cli.dart';
import 'package:mida/features/download/models/download_models.dart';

import 'cli_test_support.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mida_cli_cmd_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('version prints exactly one result line with the contract version', () async {
    final run = await runCli(['version']);
    expect(run.exitCode, 0);
    expect(run.lines, hasLength(1));
    expect(run.lines.single, '{"event":"result","kind":"version","version":"2.4.0"}');
    expect(run.last['version'], midaCliVersion);
  });

  test('sites lists the natives and the two catch-all tiers', () async {
    final run = await runCli(['sites', '--json']);
    expect(run.exitCode, 0);
    expect(run.last, {
      'event': 'result',
      'kind': 'sites',
      'native': nativeSiteIds,
      'tiers': ['generic', 'browser-capture'],
      'measured_live': measuredLiveSiteIds,
    });
    expect(nativeSiteIds, containsAll(['youtube', 'x', 'vimeo']));
    // Backward compatible: `native` is still a plain id array.
    expect((run.last['native']! as List).every((e) => e is String), isTrue);
  });

  test('resolve emits the contract shape and nothing secret', () async {
    final registry = FakeRegistry.ok();
    final run = await runCli(['resolve', testUrl], registry: registry);
    expect(run.exitCode, 0);
    expect(run.lines, hasLength(1));
    final r = run.last;
    expect(r.keys.toList(), [
      'event',
      'kind',
      'title',
      'author',
      'duration_seconds',
      'platform',
      'formats',
      'captions',
    ]);
    expect(r['kind'], 'resolve');
    expect(r['title'], 'Sample clip');
    expect(r['author'], 'Someone');
    expect(r['duration_seconds'], 90.5);
    expect(r['platform'], 'video.example.com');
    expect(r['captions'], ['en']);
    final formats = (r['formats']! as List).cast<Map<String, Object?>>();
    expect(formats.map((f) => f['id']), ['muxed-720', 'v-1080', 'a-128']);
    expect(formats.first, {
      'id': 'muxed-720',
      'ext': 'mp4',
      'height': 720,
      'fps': 30.0,
      'has_video': true,
      'has_audio': true,
      'protocol': 'https',
      'content_length': 1000,
    });
    expect(formats.last['protocol'], 'm3u8');
    for (final secret in [secretSig, secretHeader, secretCookie, 'cdn.example.com', 'Bearer']) {
      expect(run.stdoutText, isNot(contains(secret)), reason: secret);
    }
    expect(registry.resolved.single, Uri.parse(testUrl));
  });

  test('resolve reports youtube as its platform enum name', () async {
    final run = await runCli(['resolve', 'https://www.youtube.com/watch?v=abc'], registry: FakeRegistry.ok());
    expect(run.last['platform'], 'youtube');
  });

  test('download emits status, throttled progress, then the result block', () async {
    final pipeline = FakePipeline(script: (onProgress, onStatus) {
      for (var i = 0; i <= 1000; i++) {
        onProgress!(i / 1000);
      }
      onStatus!('Retrying with another format (2/3)...');
    });
    final run = await runCli(['download', testUrl, '--out', tmp.path], registry: FakeRegistry.ok(), pipeline: pipeline);
    expect(run.exitCode, 0, reason: run.stdoutText);
    expect(run.events.first, {'event': 'status', 'message': 'Resolving...'});
    final progress = run.ofEvent('progress').map((e) => e['fraction']! as num).toList();
    expect(progress.first, 0.0);
    expect(progress.last, 1.0);
    expect(progress.length, lessThanOrEqualTo(102), reason: '1% throttle');
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThan(progress[i - 1]));
    }
    final r = run.last;
    expect(r.keys.toList(), ['event', 'kind', 'output_path', 'bytes', 'video', 'audio', 'attempts']);
    expect(r['kind'], 'download');
    expect(r['output_path'], '${tmp.path}${Platform.pathSeparator}Sample clip.mp4');
    expect(r['bytes'], 5);
    expect(r['video'], {'codec': 'h264', 'width': 1920, 'height': 1080, 'duration_seconds': 90.5});
    expect(r['audio'], {'codec': 'aac'});
    expect(r['attempts'], 2);
    final call = pipeline.calls.single;
    expect(call.outputDir, tmp.path);
    expect(call.type, DownloadType.video);
    expect(call.options.videoQuality, VideoQuality.best);
    expect(call.options.subtitleOption, SubtitleOption.none);
    expect(run.stdoutText, isNot(contains(secretSig)));
  });

  test('--quiet drops progress but keeps status and result', () async {
    final pipeline = FakePipeline(script: (onProgress, _) => onProgress!(0.5));
    final run = await runCli(
      ['download', testUrl, '--out', tmp.path, '--quiet'],
      registry: FakeRegistry.ok(),
      pipeline: pipeline,
    );
    expect(run.exitCode, 0);
    expect(run.ofEvent('progress'), isEmpty);
    expect(run.ofEvent('status'), isNotEmpty);
    expect(run.last['event'], 'result');
  });

  test('download options reach the pipeline', () async {
    final pipeline = FakePipeline(fileName: 'x.m4a');
    final run = await runCli(
      [
        'download',
        testUrl,
        '--out=${tmp.path}',
        '--type',
        'audio',
        '--quality',
        '720',
        '--audio-format',
        'm4a',
        '--captions',
      ],
      registry: FakeRegistry.ok(),
      pipeline: pipeline,
    );
    expect(run.exitCode, 0, reason: run.stdoutText);
    final call = pipeline.calls.single;
    expect(call.type, DownloadType.audio);
    expect(call.options.videoQuality, VideoQuality.p720);
    expect(call.options.audioFormat, AudioFormat.m4a);
    expect(call.options.subtitleOption, SubtitleOption.koreanEnglish);
    expect(call.info.formats, hasLength(3));
  });

  test('--format-id pins one format, keeping audio for a video-only pick', () async {
    final pipeline = FakePipeline();
    await runCli(['download', testUrl, '--out', tmp.path, '--format-id', 'v-1080'],
        registry: FakeRegistry.ok(), pipeline: pipeline);
    expect(pipeline.calls.single.info.formats.map((f) => f.id), ['v-1080', 'a-128']);

    final muxed = FakePipeline();
    await runCli(['download', testUrl, '--out', tmp.path, '--format-id', 'muxed-720'],
        registry: FakeRegistry.ok(), pipeline: muxed);
    expect(muxed.calls.single.info.formats.map((f) => f.id), ['muxed-720']);
  });

  test('ffprobe unavailable: both stream blocks present with null fields', () async {
    final run = await runCli(['download', testUrl, '--out', tmp.path],
        registry: FakeRegistry.ok(), pipeline: FakePipeline(), probeFactory: fakeProbe(stdoutJson: null));
    expect(run.exitCode, 0);
    expect(run.last['video'], {'codec': null, 'width': null, 'height': null, 'duration_seconds': null});
    expect(run.last['audio'], {'codec': null});
  });

  test('audio-only file: video block is null', () async {
    final run = await runCli(['download', testUrl, '--out', tmp.path, '--type', 'audio'],
        registry: FakeRegistry.ok(),
        pipeline: FakePipeline(fileName: 'a.mp3'),
        probeFactory: fakeProbe(stdoutJson: '{"streams":[{"codec_type":"audio","codec_name":"mp3"}],"format":{}}'));
    expect(run.last['video'], isNull);
    expect(run.last['audio'], {'codec': 'mp3'});
  });

  test('every stdout line is one JSON object whose first key is event', () async {
    final run = await runCli(['download', testUrl, '--out', tmp.path],
        registry: FakeRegistry.ok(), pipeline: FakePipeline(script: (p, s) => p!(0.3)));
    expect(run.lines, isNotEmpty);
    for (final line in run.lines) {
      expect(line, startsWith('{"event":"'));
    }
    expect(run.events, hasLength(run.lines.length));
    expect(run.stderrText, isEmpty);
  });

  test('CliStreamProbe.parse rejects malformed ffprobe output', () {
    expect(CliStreamProbe.parse('not json'), isNull);
    expect(CliStreamProbe.parse('[]'), isNull);
    expect(CliStreamProbe.parse('{"streams":{}}'), isNull);
    final s = CliStreamProbe.parse('{"streams":[],"format":{"duration":12}}')!;
    expect(s.video, isNull);
    expect(s.audio, isNull);
  });
}
