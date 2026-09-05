import '../media_models.dart';
import 'page_status_detector.dart';

/// Turns one [PageStatusSignal] into the [MediaExtractionException]
/// `BrowserCaptureExtractor` throws for it - split out to keep that file
/// under this project's 400-line cap; pure (no session access) so both its
/// fast early-exit and its late "nothing was ever found" path can share
/// this one place.
class PageStatusExceptions {
  const PageStatusExceptions._();

  static MediaExtractionException forSignal(PageStatusSignal? signal) {
    switch (signal) {
      case PageStatusSignal.loginRequired:
        return const MediaExtractionException(
          'LOGIN_REQUIRED',
          'This post needs a signed-in session to view. Browser network '
              'capture cannot log in on your behalf; sign in to this site '
              'in your regular browser and try a different post, or ask '
              'the poster for a direct link.',
        );
      case PageStatusSignal.notFound:
        return const MediaExtractionException(
          'NOT_FOUND',
          'This page returned Not Found. The video may have been removed, '
              'or the URL may be incorrect. Check the link and try again.',
        );
      case PageStatusSignal.botCheckRequired:
        return const MediaExtractionException(
          'BOT_CHECK_REQUIRED',
          'This page is showing a bot-verification challenge (Cloudflare/reCAPTCHA-style). '
              'This app never attempts to solve one; open the link in your regular browser, '
              'pass the check there, and try again.',
        );
      case null:
        return const MediaExtractionException(
          'NO_MEDIA_FOUND',
          'The headless browser did not observe any media requests while '
              'loading this page. The page may require login, or the '
              'content may be private or removed.',
        );
    }
  }
}
