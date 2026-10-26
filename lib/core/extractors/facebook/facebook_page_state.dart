import 'facebook_url_matcher.dart';
import 'facebook_video_json_parser.dart';

/// Why a Facebook page that yielded no playable video yielded none.
enum FacebookPageState {
  /// Facebook asked for a sign-in: `LOGIN_REQUIRED` (the registry then tries
  /// the browser tier, which can carry the user's login session).
  loginWall,

  /// Facebook said the content is gone or not visible: terminal
  /// `NOT_FOUND`.
  notFound,

  /// Neither: the page shape is simply not understood (a technique
  /// failure, `PARSE_ERROR`, so the registry tries the other tiers).
  unknown,
}

/// Pure classification of a fetched Facebook page. Only consulted after
/// the JSON parser found no playable video, because a public video page
/// served to a signed-out visitor still carries a "Log in" form in its
/// header/footer banner: a login form next to real playback data is not a
/// login wall.
class FacebookPageStateDetector {
  const FacebookPageStateDetector._();

  static final RegExp _titleTagPattern = RegExp(r'<title\b[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false);
  static final RegExp _loginFormPattern = RegExp(r'''id\s*=\s*["']login_form["']''', caseSensitive: false);

  /// Lowercased `<title>` substrings of Facebook's sign-in page. English
  /// first (the fetcher sends `Accept-Language: en-US`), plus the Korean
  /// title observed in the 2026-09-06 live diagnosis ("Facebook에 로그인").
  static const List<String> _loginTitleMarkers = ['log in', 'log into', 'login', '로그인'];

  /// Lowercased body phrases (apostrophes normalized to `'`) Facebook
  /// shows for removed, private-to-others, or broken-link content.
  static const List<String> _notFoundMarkers = [
    "this content isn't available",
    "content isn't available right now",
    "this video isn't available",
    "this page isn't available",
    'the link you followed may be broken',
  ];

  /// A redirect that ended on Facebook's own sign-in or checkpoint page
  /// (`/login.php`, `/login/...`, `/checkpoint/...`).
  static bool isLoginRedirect(Uri effectiveUrl) {
    if (!FacebookUrlMatcher.isFacebookHost(effectiveUrl.host)) return false;
    final path = effectiveUrl.path.toLowerCase();
    return path.startsWith('/login') || path.startsWith('/checkpoint');
  }

  /// Login wall first: Facebook answers an anonymous visitor of a group- or
  /// friends-only video with its "content isn't available" text AND a login
  /// form, and a signed-in browser may well see that video. Only a
  /// not-found page with no sign-in prompt at all is terminal `NOT_FOUND`.
  static FacebookPageState classify(String html) {
    if (isLoginWall(html)) return FacebookPageState.loginWall;
    final normalized = _normalizeApostrophes(html.toLowerCase());
    if (_notFoundMarkers.any(normalized.contains)) return FacebookPageState.notFound;
    return FacebookPageState.unknown;
  }

  /// `id="login_form"` anywhere, or a `<title>` that is the sign-in page's.
  static bool isLoginWall(String html) {
    if (_loginFormPattern.hasMatch(html)) return true;
    final title = _titleTagPattern.firstMatch(html)?.group(1);
    if (title == null) return false;
    final lower = FacebookVideoJsonParser.unescapeHtml(title).toLowerCase();
    return _loginTitleMarkers.any(lower.contains);
  }

  static String _normalizeApostrophes(String text) => text
      .replaceAll('&#039;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&rsquo;', "'")
      .replaceAll('\\u2019', "'")
      .replaceAll('’', "'");
}
