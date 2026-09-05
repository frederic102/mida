import '../../services/browser_page_fetcher.dart';
import '../../utils/url_parser.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'instagram_dom_parser.dart';

/// Native Instagram extractor.
///
/// Plain HTTP against Instagram only ever returns an unpopulated SPA shell
/// (TLS-fingerprint gated); the only thing that works without a browser
/// TLS impersonation library is driving a real, installed system browser
/// headlessly and reading the DOM it renders (`BrowserPageFetcher`). This
/// class is just the glue: resolve the post URL, fetch its rendered DOM,
/// hand it to [InstagramDomParser]. Verified live 2026-09-05
/// (`docs/plan-phase2-extractors.md` Instagram section) against
/// `https://www.instagram.com/reel/Chunk8-jurw/`.
class InstagramExtractor implements MediaExtractor {
  /// `/p/`, `/reel/`, `/reels/`, `/tv/` are the post-with-media path shapes
  /// this extractor supports (per the plan's scope; stories, profiles and
  /// plain-feed pages are out of scope and fall through to
  /// `canHandle` == false).
  static final RegExp _postPathPattern = RegExp(r'^/(p|reel|reels|tv)/([^/]+)');

  final BrowserPageFetcher _fetcher;
  final InstagramDomParser _parser;

  InstagramExtractor({
    BrowserPageFetcher? fetcher,
    InstagramDomParser? parser,
  })  : _fetcher = fetcher ?? BrowserPageFetcher(),
        _parser = parser ?? const InstagramDomParser();

  @override
  bool canHandle(Uri url) =>
      UrlParser.detectPlatform(url.toString()) == PlatformType.instagram &&
      _postPathPattern.hasMatch(url.path);

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!canHandle(url)) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Not a recognizable Instagram post URL: $url',
      );
    }
    final dom = await _fetcher.fetchDom(url);
    return _parser.parse(dom, sourceUrl: url);
  }
}
