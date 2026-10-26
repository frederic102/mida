/// Pure, network-free URL recognition for `SoopExtractor`: SOOP
/// (formerly AfreecaTV) VOD player pages only.
///
/// - `vod.sooplive.co.kr/player/<nTitleNo>`
/// - `vod.afreecatv.com/player/<nTitleNo>` (legacy host, same ids)
///
/// `nTitleNo` is validated by an anchored `\d{1,12}` before it goes into
/// the API form. Live streams (`play.sooplive.co.kr`, `bj.sooplive...`) and
/// station pages do not match and are left to the generic tiers.
class SoopUrlMatcher {
  const SoopUrlMatcher._();

  static const Set<String> _hosts = {'vod.sooplive.co.kr', 'vod.afreecatv.com'};
  static final RegExp _playerPath = RegExp(r'^/player/(\d{1,12})/?$');

  /// The VOD's `nTitleNo`, or null when [url] is not a SOOP VOD player URL.
  static String? titleNo(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!_hosts.contains(url.host.toLowerCase())) return null;
    return _playerPath.firstMatch(url.path)?.group(1);
  }
}
