/// A platform's allow-list of hosts, matched by registrable-domain suffix:
/// the entry `pinimg.com` allows `pinimg.com` and `v1.pinimg.com` but not
/// `evilpinimg.com` or `pinimg.com.evil.test`.
///
/// Used by the native extractors for the hosts their media may live on (the
/// CDNs a playlist, a progressive file or an origin file may point at), so
/// an API answer cannot make MiDa fetch or offer an unrelated public server.
/// `HostPolicy` (private/loopback addresses) is a separate, additional check.
class NativeHostList {
  final List<String> suffixes;

  const NativeHostList(this.suffixes);

  /// True when [host] equals an entry or is a subdomain of one.
  bool allowsHost(String host) {
    final lower = host.toLowerCase();
    for (final suffix in suffixes) {
      if (lower == suffix || lower.endsWith('.$suffix')) return true;
    }
    return false;
  }

  /// True when [url] parses as an absolute URL whose host is allowed.
  bool allowsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.host.isNotEmpty && allowsHost(uri.host);
  }
}
