import 'dart:io';

/// Moves a finished download/conversion from a temp path to its final
/// destination. Prefers a same-volume `File.rename` (fast, effectively
/// atomic); if that fails - most commonly because [src]/[dst] are on
/// different volumes, which `rename` cannot do on Windows - falls back to
/// copy-to-a-`.part`-sibling, flush, rename that into place, then delete
/// [src]. Copying to `<dst>.part` first (rather than straight to [dst])
/// means a copy that fails partway (disk full, permission error, an
/// injected failure in a test) never leaves a partial/corrupt file at
/// [dst] itself - only a `.part` sibling, which is cleaned up before the
/// failure is rethrown.
///
/// Every rename attempt (the primary one and the fallback's own final
/// rename of its `.part` sibling) is retried up to [maxRenameAttempts]
/// times, [backoff] apart, specifically on [PathAccessException] -
/// observed live (coordinator repro, coverage probe) on Windows right
/// after a large download finishes: something else (Windows Defender or
/// another indexer/AV scanning the file it just saw appear - more
/// aggressively so, per the coordinator, in a temp directory specifically)
/// transiently holds it open, so the very next rename fails with "access
/// is denied" even though nothing in this app still has the file open.
///
/// [maxRenameAttempts]/[backoff] default to 6 attempts with exponential
/// backoff (500ms, 1s, 2s, 4s, 8s - roughly 15.5s total): a first pass at
/// this (3 attempts, 500ms flat - well under 2s total) was itself observed
/// live to still lose the race for a large file in a temp dir, where a
/// real AV/indexer scan can plausibly run several seconds, not
/// milliseconds. A failure that is *not* PathAccessException (a real
/// cross-volume EXDEV-shaped error, disk full, ...) is not retried at all,
/// since waiting will not fix it.
class FileMover {
  final Future<File> Function(File src, String dst) _rename;
  final Future<File> Function(File src, String dst) _copy;
  final Future<File> Function(File src, String dst) _finalRename;
  final int maxRenameAttempts;
  final Duration Function(int attempt) backoff;

  FileMover({
    Future<File> Function(File src, String dst)? rename,
    Future<File> Function(File src, String dst)? copy,
    Future<File> Function(File src, String dst)? finalRename,
    this.maxRenameAttempts = 6,
    Duration Function(int attempt)? backoff,
  })  : _rename = rename ?? ((src, dst) => src.rename(dst)),
        _copy = copy ?? ((src, dst) => src.copy(dst)),
        _finalRename = finalRename ?? ((src, dst) => src.rename(dst)),
        backoff = backoff ?? _defaultBackoff;

  static Duration _defaultBackoff(int attempt) => Duration(milliseconds: 500 * (1 << (attempt - 1)));

  Future<void> move(String src, String dst) async {
    if (await _tryPrimaryRename(File(src), dst)) return;

    final partPath = '$dst.part';
    try {
      await _copy(File(src), partPath);
      final handle = await File(partPath).open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
    } catch (_) {
      await _tryDeletePart(partPath);
      rethrow;
    }

    await _renameWithRetry(File(partPath), dst);
    await File(src).delete();
  }

  /// The primary same-volume rename attempt, retried on
  /// [PathAccessException] specifically. Returns `true` when it ultimately
  /// succeeded (nothing left for [move] to do); `false` for any other
  /// failure (including a [PathAccessException] that outlasted every
  /// retry), signaling [move] to fall through to the copy-based fallback.
  Future<bool> _tryPrimaryRename(File src, String dst) async {
    for (var attempt = 1; attempt <= maxRenameAttempts; attempt++) {
      try {
        await _rename(src, dst);
        return true;
      } on PathAccessException {
        if (attempt == maxRenameAttempts) return false;
        await Future.delayed(backoff(attempt));
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// The fallback path's own final rename (`<dst>.part` -> [dst]), retried
  /// the same way. Unlike [_tryPrimaryRename], a failure here really is
  /// fatal to this call: there is no further fallback past this point, so
  /// a [PathAccessException] that outlasts every retry is rethrown rather
  /// than swallowed.
  Future<void> _renameWithRetry(File src, String dst) async {
    for (var attempt = 1; attempt <= maxRenameAttempts; attempt++) {
      try {
        await _finalRename(src, dst);
        return;
      } on PathAccessException {
        if (attempt == maxRenameAttempts) rethrow;
        await Future.delayed(backoff(attempt));
      }
    }
  }

  Future<void> _tryDeletePart(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only.
    }
  }
}
