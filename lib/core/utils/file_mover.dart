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
class FileMover {
  final Future<File> Function(File src, String dst) _rename;
  final Future<File> Function(File src, String dst) _copy;

  FileMover({
    Future<File> Function(File src, String dst)? rename,
    Future<File> Function(File src, String dst)? copy,
  })  : _rename = rename ?? ((src, dst) => src.rename(dst)),
        _copy = copy ?? ((src, dst) => src.copy(dst));

  Future<void> move(String src, String dst) async {
    try {
      await _rename(File(src), dst);
      return;
    } catch (_) {
      // Fall through to copy+flush+rename+delete below (cross-volume
      // rename, or any other rename failure worth retrying a different
      // way).
    }

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

    await File(partPath).rename(dst);
    await File(src).delete();
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
