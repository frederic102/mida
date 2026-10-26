import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';
import 'package:mida/features/settings/settings_service.dart';

const _format = MediaFormat(id: 'f', url: 'https://example.invalid/v.mp4', container: 'mp4', hasVideo: true, hasAudio: true);

class _Extractor implements MediaExtractor {
  @override
  bool canHandle(Uri url) => true;

  @override
  Future<MediaInfo> extract(Uri url) async => MediaInfo(id: 'id', title: 'T', sourceUrl: url, formats: const [_format]);
}

class _InstantPipeline extends MediaDownloadPipeline {
  @override
  Future<String> download({
    required MediaInfo info,
    required DownloadType type,
    required DownloadOptions options,
    required String outputDir,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async =>
      '$outputDir/out.mp4';
}

class _FailingPipeline extends MediaDownloadPipeline {
  @override
  Future<String> download({
    required MediaInfo info,
    required DownloadType type,
    required DownloadOptions options,
    required String outputDir,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async =>
      throw StateError('failed at https://cdn.example/x.mp4?sig=SECRETSIG');
}

/// Runs [body] and returns every error that escaped as an unhandled async
/// error (what a failing Explorer launch used to become).
Future<List<Object>> _uncaught(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    await body();
    // Let the un-awaited opener run and fail.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    done.complete();
  }, (e, _) => errors.add(e));
  await done.future;
  return errors;
}

void main() {
  late int attempts;

  setUp(() {
    attempts = 0;
    FileUtils.folderOpenerOverride = (path) async {
      attempts++;
      throw const ProcessException('explorer', [], 'cannot start', 2);
    };
  });
  tearDown(() => FileUtils.folderOpenerOverride = null);

  DownloadService service() => DownloadService(
        SettingsService()..downloadSettings.downloadPath = 'C:/Out',
        registry: ExtractorRegistry([_Extractor()]),
        pipeline: _InstantPipeline(),
      );

  test('DownloadService: a failing folder opener is not an unhandled error', () async {
    DownloadTask? task;
    final errors = await _uncaught(() async {
      task = await service().download('https://a.example/v', DownloadType.video);
    });
    expect(attempts, 1, reason: 'the opener was really called');
    expect(errors, isEmpty);
    expect(task!.status, DownloadStatus.completed);
  });

  test('an unknown exception becomes task.error with URLs redacted', () async {
    final s = DownloadService(
      SettingsService()..downloadSettings.downloadPath = 'C:/Out',
      registry: ExtractorRegistry([_Extractor()]),
      pipeline: _FailingPipeline(),
    );
    final task = await s.download('https://a.example/v', DownloadType.video);
    expect(task!.status, DownloadStatus.error);
    expect(task.error, contains('https://cdn.example'));
    expect(task.error, isNot(contains('SECRETSIG')));
  });

  test('queue: a failing folder opener after the queue drains is not an unhandled error', () async {
    final s = service();
    final settings = SettingsService()..downloadSettings.downloadPath = 'C:/Out';
    final queue = DownloadQueueService(downloads: s, settings: settings);
    addTearDown(queue.dispose);
    final errors = await _uncaught(() async {
      queue.enqueueAll(['https://a.example/v'], type: DownloadType.video, options: const DownloadOptions());
      for (var i = 0; i < 20 && !queue.items.single.isFinished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    expect(queue.items.single.state, QueueItemState.done);
    expect(attempts, 1);
    expect(errors, isEmpty);
  });
}
