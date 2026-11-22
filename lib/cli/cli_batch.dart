import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/extractors/youtube/youtube_list_models.dart';
import '../core/extractors/youtube/youtube_list_target.dart';
import '../core/extractors/youtube/youtube_lister.dart';
import '../core/subscriptions/download_archive.dart';
import '../core/subscriptions/run_lock.dart';
import 'cli_args.dart';
import 'cli_download.dart';
import 'cli_events.dart';
import 'cli_exit.dart';

const _itemPause = Duration(seconds: 2);
const _rateBackoff = Duration(seconds: 30);
const _stopAfter = 3;

/// Exit code -> how bad it is; the batch exits with the worst item's code.
const _severity = {CliExit.policy: 6, CliExit.environment: 5, CliExit.rateLimited: 4, CliExit.download: 3, CliExit.extraction: 2};

int _worse(int a, int b) => a == CliExit.ok || (_severity[b] ?? 0) > (_severity[a] ?? 0) ? b : a;

/// Resolves the `<channel-or-playlist-url>` argument or ends the run.
YoutubeListTarget? _target(CliContext ctx, {required void Function(int) fail}) {
  final uri = validatedUrl(ctx.request.url!);
  if (uri == null) {
    fail(ctx.invalidUrl(ctx.request.url!));
    return null;
  }
  final target = YoutubeListTarget.parse(uri.toString());
  if (target == null) {
    fail(ctx.fail(const CliFailure(
      'UNSUPPORTED_URL',
      'Not a YouTube channel or playlist URL (use youtube.com/@handle, /channel/UC..., /c/name, /user/name or /playlist?list=...).',
      CliExit.extraction,
    )));
  }
  return target;
}

/// `list <url> [--limit N]`.
Future<int> runListCommand(CliContext ctx) async {
  int? code;
  final target = _target(ctx, fail: (c) => code = c);
  if (target == null) return code!;
  try {
    ctx.emitter.status('Listing...');
    final listing = await ctx.buildLister().list(target, maxItems: ctx.request.limit ?? YoutubeLister.defaultMaxItems);
    ctx.emitter.result('list', {
      'extractor': 'youtube',
      'source': listing.kind.name,
      'id': listing.id,
      'title': listing.title,
      'count': listing.items.length,
      'truncated': listing.truncated,
      // The watch URL is built here from a validated id, so it is printed whole.
      'items': [for (final i in listing.items) {...i.toJson(), 'url': CliTrusted(i.url.toString())}],
    });
    return CliExit.ok;
  } catch (e, st) {
    return ctx.failWith(e, st, CliStage.resolve);
  }
}

/// `download <url> --all [--limit N] [--archive FILE]`.
Future<int> runDownloadAll(CliContext ctx) async {
  int? code;
  final target = _target(ctx, fail: (c) => code = c);
  if (target == null) return code!;
  RunLock? lock;
  try {
    // With an archive, the whole run is exclusive: no second run can
    // download the same ids at the same time.
    lock = await acquireBatchLock(ctx.request.archive);
    final archive = await openBatchArchive(ctx.request.archive);
    ctx.emitter.status('Listing...');
    final listing = await ctx.buildLister().list(target, maxItems: ctx.request.limit ?? YoutubeLister.defaultMaxItems);
    final jobs = [for (final i in listing.items) BatchJob(i, ctx.request.forItem(i.url.toString()))];
    final run = BatchRun(ctx, archive);
    await run.go(jobs);
    return run.finish('download-all', {'truncated': listing.truncated});
  } on BatchArchiveError catch (e) {
    return ctx.fail(e.failure);
  } catch (e, st) {
    return ctx.failWith(e, st, CliStage.resolve);
  } finally {
    await lock?.release();
  }
}

/// Takes the run lock tied to the archive file; null when there is no archive.
/// A second run fails at once with `RUN_IN_PROGRESS` (6).
Future<RunLock?> acquireBatchLock(String? archivePath) async {
  if (archivePath == null) return null;
  try {
    return await RunLock.acquire(File(p.normalize(p.absolute(archivePath))));
  } on RunLockBusy catch (e) {
    throw BatchArchiveError(e.message, code: 'RUN_IN_PROGRESS');
  } on FileSystemException {
    throw BatchArchiveError('Cannot create the run lock next to the archive file.');
  }
}

/// Null when no `--archive` was given. An unreadable archive throws
/// [BatchArchiveError]: it must never look like "nothing downloaded yet".
Future<DownloadArchive?> openBatchArchive(String? path) async {
  if (path == null) return null;
  try {
    return await DownloadArchive.open(File(p.normalize(p.absolute(path))));
  } on FileSystemException catch (e) {
    throw BatchArchiveError('Cannot read the archive file${e.osError == null ? '' : ' (OS error ${e.osError!.errorCode})'}.');
  }
}

class BatchArchiveError implements Exception {
  final CliFailure failure;

  BatchArchiveError(String message, {String code = 'ARCHIVE_UNAVAILABLE'}) : failure = CliFailure(code, message, CliExit.environment);
}

class BatchJob {
  final YoutubeListItem item;
  final CliRequest request;

  const BatchJob(this.item, this.request);
}

/// Runs jobs one after the other: archive skip, a pause between downloads,
/// back-off on rate limits, and a stop after repeated refusals.
class BatchRun {
  final CliContext ctx;
  final DownloadArchive? archive;
  var _total = 0;
  var downloaded = 0;
  var skipped = 0;
  var failed = 0;

  /// Failures outside an item: a channel check, a file that could not be written.
  var otherFailures = 0;
  var worst = CliExit.ok;
  String? stopped;

  BatchRun(this.ctx, this.archive);

  void noteFailure(int exitCode) {
    failed++;
    worst = _worse(worst, exitCode);
  }

  void noteOther(int exitCode) {
    otherFailures++;
    worst = _worse(worst, exitCode);
  }

  /// Same-class failures in a row over the WHOLE run (all channels), kept
  /// per operation: downloads here, channel checks in [_checks]. A good RSS
  /// check says nothing about whether downloads are unblocked, so it never
  /// touches the download history, and the reverse.
  final _streak = <int, int>{};
  final _checks = <int, int>{};

  /// A channel check (RSS or channel page) failed.
  Future<void> checkFailed(int exitCode) async {
    noteOther(exitCode);
    await _afterFailure(exitCode, _checks);
  }

  /// A channel check worked: only the check history is reset.
  void checkSucceeded() => _checks.clear();

  Future<void> _afterFailure(int code, Map<int, int> streak) async {
    streak
      ..removeWhere((k, _) => k != code)
      ..update(code, (n) => n + 1, ifAbsent: () => 1);
    // A bad option fails every item alike; policy, rate limit and
    // environment failures stop the run after a streak of them.
    final reason = const {
      CliExit.usage: 'usage',
      CliExit.policy: 'policy',
      CliExit.rateLimited: 'rate_limited',
      CliExit.environment: 'environment',
    }[code];
    if (reason != null && (code == CliExit.usage || streak[code]! >= _stopAfter)) stopped = reason;
    if (stopped == null && code == CliExit.rateLimited) await ctx.pause(_rateBackoff * streak[code]!);
  }

  Future<void> go(List<BatchJob> jobs) async {
    for (final job in jobs) {
      final index = ++_total;
      if (stopped != null || ctx.emitter.terminated) continue;
      final id = job.item.id;
      try {
        await archive?.reload();
      } on FileSystemException {
        noteOther(CliExit.environment);
        ctx.emitter.item({'event': 'error', 'index': index, 'id': id, 'code': 'ARCHIVE_UNAVAILABLE', 'message': 'The archive could not be read.'});
        stopped = 'archive';
        continue;
      }
      if (archive?.contains(id) ?? false) {
        skipped++;
        ctx.emitter.item({'event': 'result', 'kind': 'skipped', 'index': index, 'id': id, 'reason': 'archived'});
        continue;
      }
      if (downloaded + failed > 0) await ctx.pause(_itemPause);
      final code = await _downloadItem(job, index);
      if (code == CliExit.ok) {
        downloaded++;
        _streak.clear();
        try {
          await archive?.add(id);
        } on FileSystemException {
          noteOther(CliExit.environment);
          ctx.emitter.item({
            'event': 'error',
            'index': index,
            'id': id,
            'code': 'ARCHIVE_UNAVAILABLE',
            'message': 'The file was saved but the archive could not be written.',
          });
          stopped = 'archive';
        }
        continue;
      }
      noteFailure(code);
      await _afterFailure(code, _streak);
    }
  }

  /// The final `batch` result; the exit code is the worst item's.
  int finish(String source, Map<String, Object?> extra) {
    ctx.emitter.result('batch', {
      'extractor': 'youtube',
      'source': source,
      'total': _total,
      'downloaded': downloaded,
      'skipped': skipped,
      'failed': failed,
      'other_failures': otherFailures,
      'stopped': stopped,
      ...extra,
    });
    return worst;
  }

  Future<int> _downloadItem(BatchJob job, int index) async {
    final state = CliRunState();
    final sink = _ItemSink(ctx.emitter, {'index': index, 'id': job.item.id});
    final emitter = CliEmitter(sink, quiet: ctx.request.quiet, state: state);
    final code = await runDownloadCommand(ctx.forItem(job.request, emitter));
    if (state.savedFile) ctx.emitter.state.savedFile = true;
    return code;
  }
}

/// Receives one item's JSON lines and re-emits them on the batch's emitter
/// with the item's `index` and `id` added, without ending the batch.
class _ItemSink implements StringSink {
  final CliEmitter _to;
  final Map<String, Object?> _extra;

  _ItemSink(this._to, this._extra);

  @override
  void writeln([Object? object = '']) {
    final event = jsonDecode(object.toString());
    if (event is Map<String, Object?>) _to.item({...event, ..._extra});
  }

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}
}
