import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Cross-process safe small-file storage: a lock around read-modify-write
/// and a replace that never leaves a half-written file.
class SafeFile {
  const SafeFile._();

  static final _queues = <String, Future<void>>{};
  static var _seq = 0;

  /// Runs [action] while this process and no other process holds the lock of
  /// [target]. Two layers: a per-path queue (OS file locks do not exclude
  /// two users inside one process on every platform) and an exclusive OS
  /// lock on `<target>.lock` (other processes, for example the CLI and the
  /// app). The lock file itself is left in place.
  static Future<T> locked<T>(File alias, Future<T> Function() action) async {
    // Every spelling of one file shares the queue and the lock file.
    final target = File(await resolvePath(alias.path));
    final key = await keyOf(target.path);
    final previous = _queues[key] ?? Future<void>.value();
    final mine = Completer<void>();
    _queues[key] = mine.future;
    await previous;
    try {
      await target.parent.create(recursive: true);
      final handle = await File('${target.path}.lock').open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        try {
          return await action();
        } finally {
          await handle.unlock();
        }
      } finally {
        await handle.close();
      }
    } finally {
      mine.complete();
      if (identical(_queues[key], mine.future)) _queues.remove(key);
    }
  }

  /// Replaces [target] with [content]: written and flushed to a uniquely
  /// named, exclusively created temp file next to it, then renamed over it.
  /// A failure before the rename leaves the original bytes alone and removes
  /// the temp file. [beforeReplace] runs after the temp file is complete and
  /// before the rename (a test seam for "the process died here").
  static Future<void> writeAtomic(File target, String content, {Future<void> Function()? beforeReplace}) async {
    // Replace the real file, never a symlink that points at it.
    target = File(await resolvePath(target.path));
    await target.parent.create(recursive: true);
    File? temp;
    for (var i = 0; i < 8 && temp == null; i++) {
      final candidate = File('${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.${_seq++}.tmp');
      try {
        await candidate.create(exclusive: true);
        temp = candidate;
      } on FileSystemException {
        if (!await candidate.exists()) rethrow;
      }
    }
    if (temp == null) throw FileSystemException('Could not create a temporary file', target.path);
    try {
      await temp.writeAsString(content, flush: true);
      await beforeReplace?.call();
      // Another process may be reading the target for a moment (Windows).
      for (var attempt = 0;; attempt++) {
        try {
          await temp.rename(target.path);
          return;
        } on FileSystemException {
          if (attempt >= 4) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
        }
      }
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // the original failure is the one to report
      }
      rethrow;
    }
  }

  /// The one real spelling of [path]: absolute, `..` folded, symlinks and
  /// junctions resolved. A file that does not exist yet is resolved through
  /// its nearest existing parent folder.
  static Future<String> resolvePath(String path) async {
    var current = p.normalize(p.absolute(path));
    final rest = <String>[];
    while (await FileSystemEntity.type(current) == FileSystemEntityType.notFound) {
      final parent = p.dirname(current);
      if (parent == current) break;
      rest.insert(0, p.basename(current));
      current = parent;
    }
    var resolved = current;
    try {
      resolved = await Directory(current).resolveSymbolicLinks();
    } on FileSystemException {
      // keep the normalized path
    }
    return p.normalize(p.joinAll([resolved, ...rest]));
  }

  /// [resolvePath], lower-cased on Windows: the identity two spellings of
  /// one file share. Locks and queues are keyed by it.
  static Future<String> keyOf(String path) async {
    final real = await resolvePath(path);
    return Platform.isWindows ? real.toLowerCase() : real;
  }
}
