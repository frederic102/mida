import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/subscriptions/run_lock.dart';
import '../core/subscriptions/storage_paths.dart';
import '../core/subscriptions/subscription.dart';
import '../core/subscriptions/subscription_check.dart';
import 'cli_batch.dart';
import 'cli_download.dart';
import 'cli_exit.dart';

/// `sync --subscriptions FILE [--archive FILE]`: for each subscribed channel
/// read the latest uploads (RSS), keep those published after the
/// subscription was created and not in the archive, download them. Writes
/// the resolved channel ids and `last_checked` back to the file (merged into
/// whatever is on disk by then, so a concurrent edit is kept).
///
/// Checked before any network access: the two files are different files, and
/// the subscriptions file is one this build can read.
Future<int> runSyncCommand(CliContext ctx) async {
  RunLock? lock;
  try {
    final subsFile = File(p.normalize(p.absolute(ctx.request.subscriptions!)));
    final archiveFile = File(p.normalize(p.absolute(ctx.request.archive ?? '${subsFile.path}.archive')));
    try {
      await ensureDistinctStorage({'--subscriptions': subsFile, '--archive': archiveFile});
    } on StorageAliasError catch (e) {
      return ctx.fail(CliFailure('INVALID_VALUE', e.message, CliExit.usage));
    }
    if (!await subsFile.exists()) {
      return ctx.fail(const CliFailure('INVALID_VALUE', 'The --subscriptions file does not exist.', CliExit.usage));
    }
    final store = SubscriptionStore(subsFile);
    final List<Subscription> subs;
    try {
      subs = await store.load();
    } on FormatException catch (e) {
      return ctx.fail(CliFailure('INVALID_VALUE', e.message, CliExit.usage));
    }
    // One sync (or other bulk run) per archive at a time, for the whole run.
    lock = await acquireBatchLock(archiveFile.path);
    final archive = await openBatchArchive(archiveFile.path);
    final lister = ctx.buildLister();
    final run = BatchRun(ctx, archive);
    final checked = <Subscription>[];
    var channelsFailed = 0;
    for (var i = 0; i < subs.length && run.stopped == null && !ctx.emitter.terminated; i++) {
      final sub = subs[i];
      ctx.emitter.status('Checking ${sub.title.isEmpty ? sub.source : sub.title}...');
      await archive!.reload();
      final SubscriptionCheck check;
      try {
        check = await checkSubscription(lister, sub, archive);
      } catch (e, st) {
        final failure = classifyError(e, stage: CliStage.resolve);
        ctx.debugLog(e, failure, st);
        ctx.emitter.item({'event': 'error', 'channel': sub.source, 'code': failure.code, 'message': failure.message});
        channelsFailed++;
        await run.checkFailed(failure.exitCode);
        continue;
      }
      run.checkSucceeded();
      checked.add(check.updated);
      final request = ctx.request.withOutDir(sub.outputDir);
      await run.go([for (final item in check.fresh) BatchJob(item, request.forItem(item.url.toString()))]);
    }
    if (checked.isNotEmpty) {
      try {
        // Only channel_id (if still null) and last_checked (never backwards).
        await store.update((current) => mergeCheckResults(current, checked));
      } on FileSystemException {
        _notSaved(ctx, run);
      } on FormatException {
        _notSaved(ctx, run);
      }
    }
    return run.finish('sync', {'channels': subs.length, 'channels_failed': channelsFailed});
  } on BatchArchiveError catch (e) {
    return ctx.fail(e.failure);
  } catch (e, st) {
    return ctx.failWith(e, st, CliStage.resolve);
  } finally {
    await lock?.release();
  }
}

void _notSaved(CliContext ctx, BatchRun run) {
  ctx.emitter.item({
    'event': 'error',
    'code': 'SUBSCRIPTIONS_NOT_SAVED',
    'message': 'The subscriptions file could not be updated.',
  });
  run.noteOther(CliExit.environment);
}
