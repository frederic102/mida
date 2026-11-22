import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../../core/extractors/youtube/youtube_list_models.dart';
import '../../../core/extractors/youtube/youtube_list_target.dart';
import '../../../core/extractors/youtube/youtube_lister.dart';
import '../../../core/subscriptions/subscription.dart';
import '../../../core/utils/display_text.dart';
import '../../download/widgets/list_error_mapping.dart';

/// The subscribed channels, read from and written to the shared
/// subscriptions file through [SubscriptionStore] (the CLI's own reader and
/// writer, with its lock and atomic replace). Every change re-reads the file
/// first, so an edit made by `mida-cli sync` in between is kept.
class SubscriptionList extends ChangeNotifier {
  SubscriptionList({required this.store, required YoutubeLister lister, DateTime Function()? now, this.storageWarning})
      : _lister = lister,
        _now = now ?? DateTime.now;

  final SubscriptionStore store;

  /// Shown on the Subscriptions screen when the data is not in a safe place.
  final String? storageWarning;
  final YoutubeLister _lister;
  final DateTime Function() _now;

  List<Subscription> _items = const [];
  String? _loadError;
  bool _disposed = false;

  List<Subscription> get items => _items;

  /// Set when the file exists but cannot be read; it is then never rewritten.
  String? get loadError => _loadError;

  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

  static bool same(Subscription a, Subscription b) => a.source == b.source && a.createdAt.isAtSameMomentAs(b.createdAt);

  Future<void> load() async {
    try {
      _items = await store.load();
      _loadError = null;
    } on FormatException catch (e) {
      _loadError = e.message;
    } on FileSystemException {
      _loadError = 'The subscriptions file could not be read.';
    }
    _notify();
  }

  /// Subscribes to a channel. The title and channel id come from listing the
  /// channel once (so a wrong link fails here, not at the first check). Only
  /// uploads published from now on are ever taken automatically. Returns an
  /// error message, or null when it worked.
  Future<String?> add(String input, {String? outputDir}) async {
    final raw = input.trim();
    final target = YoutubeListTarget.parse(_channelId.hasMatch(raw) ? 'https://www.youtube.com/channel/$raw' : raw);
    if (target == null || target.kind != YoutubeListKind.channel) {
      return 'Paste a YouTube channel link (youtube.com/@name, /channel/UC..., /c/name or /user/name). '
          'Playlists and single videos cannot be subscribed to.';
    }
    final YoutubeListing listing;
    try {
      listing = await _lister.list(target, maxItems: 1);
    } catch (e) {
      final err = describeListError(e);
      return '${err.headline} ${err.nextStep}';
    }
    var duplicate = false;
    final sub = Subscription(
      source: raw,
      channelId: listing.id,
      title: _clean(listing.title) ?? raw,
      createdAt: _now().toUtc(),
      outputDir: outputDir,
    );
    final saved = await _save((cur) {
      duplicate = cur.any((s) => s.channelId == listing.id || s.source == raw);
      return duplicate ? cur : [...cur, sub];
    });
    if (saved != null) return saved;
    return duplicate ? 'You are already subscribed to this channel.' : null;
  }

  Future<String?> remove(Subscription sub) => _save((cur) => [for (final s in cur) if (!same(s, sub)) s]);

  /// A blank title is ignored.
  Future<String?> rename(Subscription sub, String title) {
    final clean = _clean(title);
    if (clean == null) return Future.value(null);
    return _save((cur) => [for (final s in cur) same(s, sub) ? _edit(s, title: clean, outputDir: s.outputDir) : s]);
  }

  /// [dir] null = back to the default download folder.
  Future<String?> setOutputDir(Subscription sub, String? dir) =>
      _save((cur) => [for (final s in cur) same(s, sub) ? _edit(s, title: s.title, outputDir: dir) : s]);

  // Subscription.copyWith cannot clear or change the folder, so rebuild the row.
  static Subscription _edit(Subscription s, {required String title, required String? outputDir}) => Subscription(
        source: s.source,
        channelId: s.channelId,
        title: title,
        createdAt: s.createdAt,
        outputDir: outputDir,
        lastChecked: s.lastChecked,
      );

  /// A page title is untrusted text: one line, bounded.
  static String? _clean(String raw) {
    final one = displayText(raw);
    if (one.isEmpty) return null;
    return one.length > 100 ? one.substring(0, 100) : one;
  }

  Future<String?> _save(List<Subscription> Function(List<Subscription>) change) async {
    try {
      await store.update(change);
    } on FormatException catch (e) {
      return e.message;
    } on FileSystemException {
      return 'The subscriptions file could not be saved.';
    }
    await load();
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
