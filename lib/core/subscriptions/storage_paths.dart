import 'dart:io';

import 'safe_file.dart';

/// Two storage paths that are the same file, or one is a lock or temp file
/// of the other.
class StorageAliasError implements Exception {
  final String message;

  const StorageAliasError(this.message);

  @override
  String toString() => message;
}

/// Refuses [files] (label -> file) when two of them could overwrite each
/// other: the same path after resolving symlinks, junctions, `..` and case
/// (Windows), or a path that is the other's `.lock` or `.tmp` sibling.
/// Call it before reading or writing any of them. Hard links to one file are
/// not detected (Dart exposes no file identity).
Future<void> ensureDistinctStorage(Map<String, File> files) async {
  final canon = {for (final e in files.entries) e.key: await _canonical(e.value.path)};
  final labels = canon.keys.toList();
  for (var i = 0; i < labels.length; i++) {
    for (var j = i + 1; j < labels.length; j++) {
      final a = canon[labels[i]]!;
      final b = canon[labels[j]]!;
      if (a == b || _derived(a, b) || _derived(b, a)) {
        throw StorageAliasError('${labels[i]} and ${labels[j]} must be different files (they point at the same file or at each other\'s lock or temp file).');
      }
    }
  }
}

bool _derived(String candidate, String base) =>
    candidate.startsWith('$base.') && (candidate.endsWith('.lock') || candidate.endsWith('.tmp'));

Future<String> _canonical(String path) => SafeFile.keyOf(path);
