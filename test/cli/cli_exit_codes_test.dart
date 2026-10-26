import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_exit.dart';
import 'package:mida/core/download/caption_downloader.dart';
import 'package:mida/core/download/hls_ffmpeg_args.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/cdp_client.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';

import 'cli_test_support.dart';

/// One expected mapping: [error] raised at a stage, the JSON `code`, and
/// the process exit code from the contract table.
class _Case {
  final String name;
  final Object error;
  final String code;
  final int exit;

  const _Case(this.name, this.error, this.code, this.exit);
}

MediaExtractionException _mee(String status) => MediaExtractionException(status, 'reason for $status');

final _resolveStage = <_Case>[
  _Case('HEADLESS_BLOCKED', _mee('HEADLESS_BLOCKED'), 'HEADLESS_BLOCKED', 5),
  _Case('LOGIN_REQUIRED', _mee('LOGIN_REQUIRED'), 'LOGIN_REQUIRED', 5),
  _Case('DRM_PROTECTED', _mee('DRM_PROTECTED'), 'DRM_PROTECTED', 5),
  _Case('DRM', _mee('DRM'), 'DRM', 5),
  _Case('BOT_CHECK_REQUIRED', _mee('BOT_CHECK_REQUIRED'), 'BOT_CHECK_REQUIRED', 5),
  _Case('PRIVATE', _mee('PRIVATE'), 'PRIVATE', 5),
  _Case('BROWSER_MISSING', _mee('BROWSER_MISSING'), 'BROWSER_MISSING', 6),
  _Case('NETWORK', _mee('NETWORK'), 'NETWORK', 6),
  _Case('RATE_LIMITED', _mee('RATE_LIMITED'), 'RATE_LIMITED', 7),
  _Case('NO_MEDIA_FOUND', _mee('NO_MEDIA_FOUND'), 'NO_MEDIA_FOUND', 3),
  _Case('UNSUPPORTED_URL', _mee('UNSUPPORTED_URL'), 'UNSUPPORTED_URL', 3),
  _Case('PARSE_ERROR', _mee('PARSE_ERROR'), 'PARSE_ERROR', 3),
  _Case('unlisted status NOT_FOUND', _mee('NOT_FOUND'), 'NOT_FOUND', 3),
  const _Case('CdpCommandException', CdpCommandException('Page.navigate', {'message': 'x'}), 'BROWSER_CAPTURE_FAILED', 3),
  const _Case('SocketException', SocketException('refused'), 'NETWORK', 6),
  _Case('unknown error', StateError('weird'), 'EXTRACTION_FAILED', 3),
];

final _downloadStage = <_Case>[
  const _Case('NoDownloadableFormatsException', NoDownloadableFormatsException(), 'NO_DOWNLOADABLE_FORMATS', 3),
  const _Case('StreamDownloadException', StreamDownloadException('chunk failed'), 'DOWNLOAD_FAILED', 4),
  const _Case('MediaMergeException', MediaMergeException('mux failed'), 'MERGE_FAILED', 4),
  const _Case('CaptionDownloadException', CaptionDownloadException('vtt failed'), 'CAPTION_FAILED', 4),
  const _Case('HeaderInjectionException', HeaderInjectionException('Refusing header "X: $secretHeader"'), 'UNSAFE_HEADER', 4),
  const _Case('CdpCommandException', CdpCommandException('Network.enable', 'x'), 'BROWSER_CAPTURE_FAILED', 4),
  const _Case('ProcessException', ProcessException('ffmpeg', []), 'FFMPEG_MISSING', 6),
  _Case('unlisted status NOT_FOUND', _mee('NOT_FOUND'), 'NOT_FOUND', 4),
  _Case('policy status from a candidate', _mee('LOGIN_REQUIRED'), 'LOGIN_REQUIRED', 5),
  _Case('unknown error', StateError('weird'), 'DOWNLOAD_FAILED', 4),
  const _Case(
    'all candidates failed: stream',
    AllFormatCandidatesFailedException(3, StreamDownloadException('x')),
    'DOWNLOAD_FAILED',
    4,
  ),
  _Case(
    'all candidates failed: last was rate limited',
    AllFormatCandidatesFailedException(2, _mee('RATE_LIMITED')),
    'RATE_LIMITED',
    7,
  ),
  const _Case(
    'all candidates failed: ffmpeg missing',
    AllFormatCandidatesFailedException(1, ProcessException('ffmpeg', [])),
    'FFMPEG_MISSING',
    6,
  ),
  const _Case(
    'all candidates failed: zero attempts, nothing downloadable',
    AllFormatCandidatesFailedException(0, NoDownloadableFormatsException()),
    'NO_DOWNLOADABLE_FORMATS',
    3,
  ),
  const _Case(
    'all candidates failed: nothing downloadable after attempts',
    AllFormatCandidatesFailedException(2, NoDownloadableFormatsException()),
    'DOWNLOAD_FAILED',
    4,
  ),
];

void _expectError(CliRun run, String code, int exit) {
  expect(run.exitCode, exit, reason: run.stdoutText);
  expect(run.last['event'], 'error');
  expect(run.last['code'], code);
  expect(run.last['message'], isA<String>());
  expect((run.last['message']! as String).isNotEmpty, isTrue);
  expect(run.stdoutText, isNot(contains(secretHeader)));
  expect(run.ofEvent('result'), isEmpty);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mida_cli_exit_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('exit code constants match the contract table', () {
    expect([CliExit.ok, CliExit.usage, CliExit.extraction, CliExit.download, CliExit.policy, CliExit.environment],
        [0, 2, 3, 4, 5, 6]);
    expect(CliExit.rateLimited, 7);
  });

  group('resolve command, failure while resolving', () {
    for (final c in _resolveStage) {
      test(c.name, () async {
        final run = await runCli(['resolve', testUrl], registry: FakeRegistry.throwing(c.error));
        _expectError(run, c.code, c.exit);
      });
    }
  });

  group('download command, failure in its resolve step', () {
    for (final c in _resolveStage) {
      test(c.name, () async {
        final pipeline = FakePipeline();
        final run = await runCli(['download', testUrl, '--out', tmp.path],
            registry: FakeRegistry.throwing(c.error), pipeline: pipeline);
        _expectError(run, c.code, c.exit);
        expect(pipeline.calls, isEmpty);
      });
    }
  });

  group('download command, failure inside the pipeline', () {
    for (final c in _downloadStage) {
      test(c.name, () async {
        final run = await runCli(['download', testUrl, '--out', tmp.path],
            registry: FakeRegistry.ok(), pipeline: FakePipeline(error: c.error));
        _expectError(run, c.code, c.exit);
      });
    }
  });

  group('usage errors exit 2', () {
    final cases = <String, (List<String>, String)>{
      'no arguments': (<String>[], 'USAGE'),
      'unknown command': (['fetch', testUrl], 'USAGE'),
      'missing url': (['download'], 'USAGE'),
      'two urls': (['resolve', testUrl, testUrl], 'USAGE'),
      'option not valid for command': (['resolve', testUrl, '--out', 'x'], 'USAGE'),
      'unknown option': (['download', testUrl, '--bogus'], 'USAGE'),
      'single dash option': (['download', testUrl, '-o'], 'USAGE'),
      'value missing': (['download', testUrl, '--out'], 'USAGE'),
      'flag given a value': (['download', testUrl, '--headless=1'], 'USAGE'),
      'bad --quality': (['download', testUrl, '--quality', '999'], 'INVALID_VALUE'),
      'bad --type': (['download', testUrl, '--type', 'gif'], 'INVALID_VALUE'),
      'bad --audio-format': (['download', testUrl, '--audio-format', 'aiff'], 'INVALID_VALUE'),
      'sites takes no url': (['sites', testUrl], 'USAGE'),
      'not an http url': (['resolve', 'ftp://example.com/a'], 'INVALID_URL'),
    };
    cases.forEach((name, c) {
      test(name, () async {
        final run = await runCli(c.$1, registry: FakeRegistry.ok(), pipeline: FakePipeline());
        _expectError(run, c.$2, 2);
        expect(run.lines, hasLength(1));
      });
    });

    test('unknown --format-id', () async {
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', tmp.path, '--format-id', 'nope'],
          registry: FakeRegistry.ok(), pipeline: pipeline);
      _expectError(run, 'FORMAT_NOT_FOUND', 2);
      expect(pipeline.calls, isEmpty);
    });

    test('--out pointing at a file', () async {
      final file = File('${tmp.path}${Platform.pathSeparator}taken.txt')..writeAsStringSync('x');
      final run = await runCli(['download', testUrl, '--out', file.path],
          registry: FakeRegistry.ok(), pipeline: FakePipeline());
      _expectError(run, 'INVALID_OUT', 2);
    });
  });

  test('no --out and no home folder in the environment exits 6', () async {
    final pipeline = FakePipeline();
    final run = await runCli(['download', testUrl], registry: FakeRegistry.ok(), pipeline: pipeline);
    _expectError(run, 'OUTPUT_DIR_UNAVAILABLE', 6);
    expect(pipeline.calls, isEmpty);
  });

  test('pipeline returns a path that does not exist: exit 4', () async {
    final run = await runCli(['download', testUrl, '--out', tmp.path],
        registry: FakeRegistry.ok(), pipeline: FakePipeline(writeFile: false));
    _expectError(run, 'DOWNLOAD_FAILED', 4);
  });

  test('AllFormatCandidatesFailed message carries the classified inner reason', () {
    final f = classifyError(
      const AllFormatCandidatesFailedException(1, HeaderInjectionException('Refusing header "$secretHeader"')),
      stage: CliStage.download,
    );
    expect(f.message, contains('tried 1 format(s)'));
    expect(f.message, isNot(contains(secretHeader)));
  });
}
