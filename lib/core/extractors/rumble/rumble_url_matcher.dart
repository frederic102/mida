/// What [RumbleUrlMatcher.match] recognized. Exactly one of [embedId] and
/// [pageSlug] is set; both are validated, so a URL built from them cannot
/// carry anything else.
class RumbleRef {
  /// The player id from `rumble.com/embed/<id>/`, ready for the embedJS call.
  final String? embedId;

  /// The `<slug>` of `rumble.com/<slug>.html`; the page must be fetched once
  /// to learn its embed id.
  final String? pageSlug;

  const RumbleRef.embed(String this.embedId) : pageSlug = null;
  const RumbleRef.page(String this.pageSlug) : embedId = null;

  Uri get pageUrl => Uri.https('rumble.com', '/$pageSlug.html');
}

/// Pure, network-free URL recognition for the Rumble extractor.
///
/// - `rumble.com/<slug>.html` (also `www.rumble.com`)
/// - `rumble.com/embed/<id>` and `rumble.com/embed/<id>/` (the query, such as
///   `?pub=`, is ignored)
///
/// Channel (`/c/`, `/user/`), category and search pages do not end in
/// `.html` and never match.
class RumbleUrlMatcher {
  const RumbleUrlMatcher._();

  static const Set<String> _hosts = {'rumble.com', 'www.rumble.com'};

  static final RegExp pageSlug = RegExp(r'^/([A-Za-z0-9][A-Za-z0-9._~-]{0,199})\.html$');
  static final RegExp embedPath = RegExp(r'^/embed/([0-9A-Za-z]{3,16})/?$');

  /// A player id as it appears in `embedUrl`/oEmbed values on a page.
  static final RegExp embedId = RegExp(r'^[0-9A-Za-z]{3,16}$');

  static RumbleRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!_hosts.contains(url.host.toLowerCase())) return null;

    final embed = embedPath.firstMatch(url.path);
    if (embed != null) return RumbleRef.embed(embed.group(1)!);

    final page = pageSlug.firstMatch(url.path);
    if (page != null) return RumbleRef.page(page.group(1)!);
    return null;
  }
}
