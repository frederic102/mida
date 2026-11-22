import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../core/extractors/youtube/youtube_list_models.dart';
import '../../../core/extractors/youtube/youtube_list_target.dart';
import '../../../core/extractors/youtube/youtube_lister.dart';

enum ChannelListPhase { idle, loading, error, loaded }

/// The channel or playlist [url] stands for, or null when it is anything
/// else. A `watch?v=...&list=...` or `youtu.be/...` link is a video that
/// happens to sit in a playlist: it stays a normal link (paste the
/// `playlist?list=` URL to get the list).
YoutubeListTarget? listTargetOf(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.toLowerCase() == 'youtu.be' || uri.queryParameters.containsKey('v')) return null;
  return YoutubeListTarget.parse(url);
}

/// State of the "channel or playlist" list under the URL field: which URL it
/// is for, loading, error, the loaded videos and which of them are ticked.
/// Titles and ids come from a web page and are only ever shown or turned
/// into watch URLs by [YoutubeListItem.url].
class ChannelListController extends ChangeNotifier {
  ChannelListController(this._lister, {this.debounce = const Duration(milliseconds: 500)});

  final YoutubeLister _lister;

  /// Wait after the URL last changed before listing, so typing a handle
  /// letter by letter does not fire a request per letter.
  final Duration debounce;

  ChannelListPhase _phase = ChannelListPhase.idle;
  YoutubeListing? _listing;
  Object? _error;
  final Set<String> _selected = {};
  String? _url;
  List<String> _ignored = const [];
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  ChannelListPhase get phase => _phase;
  YoutubeListing? get listing => _listing;
  Object? get error => _error;
  String? get url => _url;

  /// Further channel or playlist links in the field: only the first one gets
  /// a list, the card names these so they are not silently dropped.
  List<String> get ignoredUrls => _ignored;
  int get selectedCount => _selected.length;
  bool isSelected(String id) => _selected.contains(id);

  /// The ticked videos in list order.
  List<YoutubeListItem> get selectedItems => [
        for (final i in _listing?.items ?? const <YoutubeListItem>[])
          if (_selected.contains(i.id)) i,
      ];

  /// Call with every link in the URL field. The first channel or playlist
  /// link decides; no such link clears the list. The same link again does
  /// nothing (no reload on every keystroke).
  void updateUrls(Iterable<String> urls) {
    final lists = [for (final u in urls) if (listTargetOf(u) != null) u];
    final next = lists.isEmpty ? null : lists.first;
    final ignored = lists.skip(1).toList();
    final ignoredChanged = !listEquals(ignored, _ignored);
    _ignored = ignored;
    if (next == _url) {
      if (ignoredChanged) _notify();
      return;
    }
    _timer?.cancel();
    _generation++;
    _url = next;
    _selected.clear();
    _listing = null;
    _error = null;
    _phase = next == null ? ChannelListPhase.idle : ChannelListPhase.loading;
    _notify();
    if (next != null) {
      final gen = _generation;
      _timer = Timer(debounce, () => _load(next, gen));
    }
  }

  /// Loads the current link again after an error.
  Future<void> retry() {
    final url = _url;
    if (url == null) return Future.value();
    _timer?.cancel();
    return _load(url, ++_generation);
  }

  Future<void> _load(String url, int generation) async {
    _phase = ChannelListPhase.loading;
    _error = null;
    _notify();
    try {
      final listing = await _lister.list(listTargetOf(url)!);
      if (generation != _generation) return;
      _listing = listing;
      _phase = ChannelListPhase.loaded;
    } catch (e) {
      if (generation != _generation) return;
      _error = e;
      _phase = ChannelListPhase.error;
    }
    _notify();
  }

  void toggle(String id) {
    if (!_selected.remove(id)) _selected.add(id);
    _notify();
  }

  void selectAll() {
    _selected
      ..clear()
      ..addAll([for (final i in _listing?.items ?? const <YoutubeListItem>[]) i.id]);
    _notify();
  }

  void selectNone() {
    _selected.clear();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
