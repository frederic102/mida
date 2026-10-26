import '../../../core/utils/url_parser.dart';

/// Result of splitting the URL field (or clipboard text) into links.
class UrlBatch {
  const UrlBatch({required this.urls, required this.skipped});

  /// Unique http(s) links in the order they were typed or pasted.
  final List<String> urls;

  /// Non-empty tokens that were not http(s) links (typos, `ftp://`, text).
  final int skipped;

  bool get isEmpty => urls.isEmpty;

  static const empty = UrlBatch(urls: [], skipped: 0);

  /// Splits [text] on any whitespace (newlines, spaces, tabs), keeps the
  /// tokens that are http(s) URLs with a host, and drops repeats.
  static UrlBatch parse(String text) {
    final urls = <String>[];
    final seen = <String>{};
    var skipped = 0;
    for (final token in text.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      if (!isHttpLink(token)) {
        skipped++;
        continue;
      }
      if (seen.add(token)) urls.add(token);
    }
    return UrlBatch(urls: urls, skipped: skipped);
  }
}

/// True for an absolute `http://` or `https://` URL that names a host.
bool isHttpLink(String value) {
  if (!UrlParser.isValidUrl(value)) return false;
  final uri = Uri.tryParse(value);
  return uri != null && uri.host.isNotEmpty;
}

/// Short label for a link: host without a leading `www.`.
String linkHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// What the clipboard chip should offer, or null when it should stay
/// hidden: only http(s) links that are neither already in the queue
/// ([queuedUrls]) nor already typed into the field ([fieldText]), and not
/// clipboard text the user already dismissed ([dismissedText]).
List<String>? clipboardSuggestion({
  required String? clipboardText,
  required Iterable<String> queuedUrls,
  required String fieldText,
  String? dismissedText,
}) {
  final text = clipboardText?.trim() ?? '';
  if (text.isEmpty || text == dismissedText?.trim()) return null;
  final known = {...queuedUrls, ...UrlBatch.parse(fieldText).urls};
  final fresh = UrlBatch.parse(text).urls.where((u) => !known.contains(u)).toList();
  return fresh.isEmpty ? null : fresh;
}
