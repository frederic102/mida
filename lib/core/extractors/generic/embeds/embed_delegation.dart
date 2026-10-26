import '../../media_models.dart';
import 'embed_resolver.dart';

/// "This page's video lives on a platform a native extractor already
/// covers; resolve [target] instead." Thrown by [DelegatingEmbedResolver]
/// (through `GenericExtractor.extract`) rather than re-implementing
/// YouTube/Vimeo/Dailymotion here.
///
/// Deliberately a `MediaExtractionException` with status `NO_MEDIA_FOUND`:
/// until `ExtractorRegistry` learns to act on it, every existing caller
/// treats it exactly like the catch-all extractor's ordinary "nothing on
/// this page" result (same fall-through to browser capture, same CLI exit
/// code), so adding it cannot regress anything. A registry that does know
/// about it re-resolves [target] once (see the wiring note in the lane
/// report / `embed_resolver_chain.dart`).
class EmbedDelegationException extends MediaExtractionException {
  /// Canonical public URL of the embedded item (a watch/video page URL, not
  /// the embed URL), built only from a strictly validated id.
  final Uri target;

  /// Human name of the platform the embed belongs to (`YouTube`, ...).
  final String platform;

  EmbedDelegationException(this.target, {required this.platform})
      : super(
          'NO_MEDIA_FOUND',
          'This page embeds a $platform player. The video itself is at $target; '
              'open that link directly to download it.',
        );
}

/// One delegation rule: how to spot a platform's embed iframe and rebuild
/// the canonical URL its native extractor accepts.
class _DelegationRule {
  final String platform;
  final RegExp pattern;
  final Uri Function(Match match, String src) canonical;

  const _DelegationRule(this.platform, this.pattern, this.canonical);
}

/// Spots YouTube, Vimeo, and Dailymotion player iframes (`src` or lazy
/// `data-src`) and throws [EmbedDelegationException] with the canonical
/// URL instead of resolving anything itself: those platforms already have
/// native extractors, which must stay the single implementation.
///
/// Only `<iframe>` sources count: a plain link to a YouTube video elsewhere
/// on the page is not the page's embedded player.
class DelegatingEmbedResolver implements EmbedResolver {
  const DelegatingEmbedResolver();

  @override
  String get platform => 'embedded player';

  static final List<_DelegationRule> _rules = [
    _DelegationRule(
      'YouTube',
      RegExp(r'^(?:https?:)?//(?:www\.|m\.)?youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})(?:[?#/]|$)',
          caseSensitive: false),
      (m, _) => Uri.https('www.youtube.com', '/watch', {'v': m.group(1)!}),
    ),
    _DelegationRule(
      'Vimeo',
      RegExp(r'^(?:https?:)?//player\.vimeo\.com/video/(\d{1,15})(?:[/?#]|$)', caseSensitive: false),
      _vimeoCanonical,
    ),
    _DelegationRule(
      'Dailymotion',
      RegExp(r'^(?:https?:)?//(?:www\.)?dailymotion\.com/embed/video/([a-zA-Z0-9]{1,20})(?:[?#/]|$)',
          caseSensitive: false),
      (m, _) => Uri.https('www.dailymotion.com', '/video/${m.group(1)}'),
    ),
    _DelegationRule(
      'Dailymotion',
      RegExp(r'^(?:https?:)?//geo\.dailymotion\.com/player(?:/[A-Za-z0-9_-]+)?\.html\?(?:[^#]*?&)?video=([a-zA-Z0-9]{1,20})\b',
          caseSensitive: false),
      (m, _) => Uri.https('www.dailymotion.com', '/video/${m.group(1)}'),
    ),
  ];

  /// Keeps an unlisted video's privacy hash (`?h=`), which the native
  /// Vimeo extractor forwards exactly as the embed player does.
  /// A malformed query (`?h=%FF` is not valid UTF-8 once decoded) is no
  /// hash at all rather than an exception: this runs inside `matches()`.
  static Uri _vimeoCanonical(Match match, String src) {
    final absolute = src.startsWith('//') ? 'https:$src' : src;
    String? hash;
    try {
      hash = Uri.tryParse(absolute)?.queryParameters['h'];
    } on FormatException {
      hash = null;
    } on ArgumentError {
      hash = null;
    }
    final validHash = hash != null && RegExp(r'^[0-9a-f]{1,40}$').hasMatch(hash);
    return Uri.https('player.vimeo.com', '/video/${match.group(1)}', validHash ? {'h': hash} : null);
  }

  /// First delegation target among [html]'s iframes, in document order.
  static EmbedDelegationException? findDelegation(String html) {
    for (final src in EmbedSupport.iframeSources(html)) {
      final trimmed = src.trim();
      for (final rule in _rules) {
        final match = rule.pattern.firstMatch(trimmed);
        if (match != null) return EmbedDelegationException(rule.canonical(match, trimmed), platform: rule.platform);
      }
    }
    return null;
  }

  @override
  bool matches(String html) => findDelegation(html) != null;

  /// Never returns media: either throws the delegation or (no embed after
  /// all) returns null. No network.
  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async {
    final delegation = findDelegation(request.html);
    if (delegation != null) throw delegation;
    return null;
  }
}
