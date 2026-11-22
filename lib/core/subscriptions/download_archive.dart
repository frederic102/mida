import 'dart:io';

import 'safe_file.dart';

/// The set of video ids already downloaded, kept in a text file with one id
/// per line. Pure `dart:io`, shared by the CLI and the GUI so a video is
/// never downloaded twice by the subscription path. Several writers (the CLI
/// and the app) may share one file: every [add] re-reads the file under a
/// cross-process lock, merges, and replaces it atomically, so no writer's
/// ids are lost.
class DownloadArchive {
  static final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');

  final File file;
  final Set<String> _ids;

  DownloadArchive._(this.file, this._ids);

  /// Reads [file] (a missing file is an empty archive). Lines that are not
  /// video ids are ignored; an unreadable file throws, so a broken archive
  /// never turns into "nothing downloaded yet".
  static Future<DownloadArchive> open(File file) async => DownloadArchive._(file, await _read(file));

  static Future<Set<String>> _read(File file) async {
    final ids = <String>{};
    if (await FileSystemEntity.isDirectory(file.path)) {
      throw FileSystemException('The archive path is a folder', file.path);
    }
    if (await file.exists()) {
      for (final line in (await file.readAsString()).split('\n')) {
        final id = line.trim();
        if (_id.hasMatch(id)) ids.add(id);
      }
    }
    return ids;
  }

  bool contains(String id) => _ids.contains(id);

  int get length => _ids.length;

  /// Picks up ids other writers saved since this snapshot was taken.
  Future<void> reload() async {
    final disk = await _read(file);
    _ids.addAll(disk);
  }

  /// Records [id]. The file is re-read under the lock first, so ids added by
  /// another writer since [open] stay in the file. On failure nothing is
  /// remembered and the old file is untouched.
  Future<void> add(String id, {Future<void> Function()? beforeReplace}) async {
    if (!_id.hasMatch(id)) throw ArgumentError.value(id, 'id', 'Not a video id');
    await SafeFile.locked(file, () async {
      final merged = await _read(file);
      if (merged.add(id)) {
        await SafeFile.writeAtomic(file, '${merged.join('\n')}\n', beforeReplace: beforeReplace);
      }
      _ids.addAll(merged);
    });
  }
}
