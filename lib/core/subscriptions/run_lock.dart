import 'dart:io';

import 'safe_file.dart';

/// Another run already holds the lock.
class RunLockBusy implements Exception {
  final String message;

  const RunLockBusy(this.message);

  @override
  String toString() => message;
}

/// One bulk run at a time per archive, across processes (the CLI, the app's
/// subscription check). Held for the WHOLE run: it covers "is this id
/// already downloaded?", the download and the archive write, so two runs can
/// never download the same video at once. Tied to `<archive>.run.lock`; the
/// OS drops the lock if the process dies, so a crash never leaves it stuck.
class RunLock {
  static final _heldHere = <String>{};

  final RandomAccessFile _handle;
  final String _key;
  var _released = false;

  RunLock._(this._handle, this._key);

  /// Takes the lock for [archive] or throws [RunLockBusy] after [wait]
  /// (default: at once).
  static Future<RunLock> acquire(File archive, {Duration wait = Duration.zero}) async {
    // The lock belongs to the real file: a symlink, a junction or a `..`
    // spelling of the archive takes the very same lock file and key.
    final real = File(await SafeFile.resolvePath(archive.path));
    final key = await SafeFile.keyOf(real.path);
    final deadline = DateTime.now().add(wait);
    while (true) {
      if (!_heldHere.contains(key)) {
        await real.parent.create(recursive: true);
        final handle = await File('${real.path}.run.lock').open(mode: FileMode.append);
        try {
          await handle.lock(FileLock.exclusive);
          _heldHere.add(key);
          return RunLock._(handle, key);
        } on FileSystemException {
          await handle.close();
        }
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw const RunLockBusy('Another MiDa run is already using this archive. Wait for it to finish, then start again.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heldHere.remove(_key);
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
    }
  }
}
