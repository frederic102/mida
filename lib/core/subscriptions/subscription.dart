import 'dart:convert';
import 'dart:io';

import '../extractors/youtube/youtube_list_models.dart';
import 'download_archive.dart';
import 'safe_file.dart';

/// One subscribed channel. Pure data: no Flutter, no network.
class Subscription {
  /// What the user pasted: a `UC...` channel id or a channel URL.
  final String source;

  /// The resolved `UC...` id; null until the channel page was read once.
  final String? channelId;
  final String title;

  /// Only uploads published after this time are taken automatically.
  final DateTime createdAt;

  /// Per-channel output folder; null = the default one.
  final String? outputDir;
  final DateTime? lastChecked;

  const Subscription({
    required this.source,
    required this.title,
    required this.createdAt,
    this.channelId,
    this.outputDir,
    this.lastChecked,
  });

  Subscription copyWith({String? channelId, String? title, DateTime? lastChecked}) => Subscription(
        source: source,
        title: title ?? this.title,
        createdAt: createdAt,
        channelId: channelId ?? this.channelId,
        outputDir: outputDir,
        lastChecked: lastChecked ?? this.lastChecked,
      );

  Map<String, Object?> toJson() => {
        'source': source,
        'channel_id': channelId,
        'title': title,
        'created_at': createdAt.toUtc().toIso8601String(),
        'output_dir': outputDir,
        'last_checked': lastChecked?.toUtc().toIso8601String(),
      };

  /// Throws [FormatException] for anything that is not a subscription.
  factory Subscription.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('A subscription must be an object.');
    String? str(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is String) return v;
      throw FormatException('"$key" must be a string.');
    }

    DateTime? time(String key) {
      final s = str(key);
      if (s == null) return null;
      return DateTime.tryParse(s)?.toUtc() ?? (throw FormatException('"$key" is not a date.'));
    }

    final source = str('source');
    final created = time('created_at');
    if (source == null || source.trim().isEmpty) throw const FormatException('"source" is required.');
    if (created == null) throw const FormatException('"created_at" is required.');
    return Subscription(
      source: source,
      channelId: str('channel_id'),
      title: str('title') ?? '',
      createdAt: created,
      outputDir: str('output_dir'),
      lastChecked: time('last_checked'),
    );
  }
}

/// Folds the results of a run into the rows on disk NOW. A run owns exactly
/// two fields: `channel_id` (only while it is still null) and `last_checked`
/// (the later of the two times, so overlapping runs never move it back).
/// Titles, output folders and creation times are never touched. A result
/// applies only to a row with the same `source` AND `created_at`, so a row
/// that was removed stays removed, and one removed and added again (new
/// `created_at`) is not mistaken for its predecessor.
List<Subscription> mergeCheckResults(List<Subscription> current, Iterable<Subscription> checked) => [
      for (final row in current)
        () {
          var merged = row;
          for (final r in checked) {
            if (r.source != row.source || !r.createdAt.isAtSameMomentAs(row.createdAt)) continue;
            final later = r.lastChecked != null && (merged.lastChecked == null || r.lastChecked!.isAfter(merged.lastChecked!));
            merged = merged.copyWith(
              channelId: merged.channelId == null ? r.channelId : null,
              lastChecked: later ? r.lastChecked : null,
            );
          }
          return merged;
        }(),
    ];

/// The uploads of [items] that a subscription may queue on its own: published
/// strictly after [createdAt] and not in [archive]. Items without a publish
/// time are skipped (fail closed: no surprise back-catalogue download).
List<YoutubeListItem> newUploadsSince(
  Iterable<YoutubeListItem> items, {
  required DateTime createdAt,
  required DownloadArchive archive,
}) =>
    [
      for (final i in items)
        if (i.published != null && i.published!.isAfter(createdAt) && !archive.contains(i.id)) i,
    ];

/// Reads and writes the subscriptions JSON file:
/// `{"version": 1, "subscriptions": [...]}`.
class SubscriptionStore {
  final File file;

  const SubscriptionStore(this.file);

  static const supportedVersion = 1;

  /// A missing file is an empty list; a malformed one, or one with a
  /// version other than [supportedVersion], throws [FormatException] and is
  /// never rewritten.
  Future<List<Subscription>> load() async {
    if (!await file.exists()) return [];
    final Object? json;
    try {
      json = jsonDecode(await file.readAsString());
    } on FormatException {
      throw const FormatException('The subscriptions file is not valid JSON.');
    }
    if (json is! Map) throw const FormatException('The subscriptions file is not an object.');
    final version = json['version'];
    if (version != supportedVersion) {
      throw FormatException('Unsupported subscriptions file version ${version is int ? version : '(missing)'}; this build reads version $supportedVersion.');
    }
    final list = json['subscriptions'];
    if (list is! List) throw const FormatException('The subscriptions file has no "subscriptions" list.');
    return [for (final s in list) Subscription.fromJson(s)];
  }

  /// Re-reads the file under a cross-process lock, applies [change] to what
  /// is on disk now, and replaces the file atomically. A file this build
  /// cannot read is left byte for byte as it was.
  Future<void> update(List<Subscription> Function(List<Subscription> current) change) =>
      SafeFile.locked(file, () async {
        final next = change(await load());
        final text = const JsonEncoder.withIndent('  ').convert({
          'version': supportedVersion,
          'subscriptions': [for (final s in next) s.toJson()],
        });
        await SafeFile.writeAtomic(file, '$text\n');
      });

  /// Replaces the list (still validates the existing file first).
  Future<void> save(List<Subscription> subscriptions) => update((_) => subscriptions);
}
