/// Shared HTTP constants for the generic extractor's own requests (page
/// GET, Content-Type probe, playlist GET). Kept in one place so the
/// User-Agent used to fetch a page matches the one recorded in
/// `MediaInfo.requestHeaders` for the formats found on it; some CDNs pin
/// the UA that first requested a manifest/segment.
const String genericDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

const String genericAcceptLanguage = 'en-US,en;q=0.9';
