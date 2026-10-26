/// What [BlueskyUrlMatcher.match] recognized: the account (a handle or a
/// DID) and the record key of the post, both validated with anchored
/// patterns before they can reach any API URL.
class BlueskyPostRef {
  /// Lowercased handle (`alice.bsky.social`) or a DID (`did:plc:...`).
  final String actor;
  final String rkey;

  const BlueskyPostRef({required this.actor, required this.rkey});

  bool get actorIsDid => actor.startsWith('did:');

  /// The `at://` URI of the post once [did] is known.
  String atUri(String did) => 'at://$did/app.bsky.feed.post/$rkey';
}

/// Pure, network-free URL recognition for the Bluesky extractor:
/// `bsky.app/profile/<handle-or-did>/post/<rkey>` (also `www.bsky.app`).
///
/// - handle: dot-separated DNS labels, at most 253 characters, final label
///   starting with a letter (the atproto handle syntax).
/// - DID: `did:plc:` plus 24 base32 characters, or `did:web:` plus a host name.
/// - rkey: a 13-character TID (base32-sortable alphabet), what every post
///   created by the Bluesky apps uses.
class BlueskyUrlMatcher {
  const BlueskyUrlMatcher._();

  static const Set<String> _hosts = {'bsky.app', 'www.bsky.app'};

  static final RegExp handlePattern = RegExp(
    r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
  );
  static final RegExp didPattern = RegExp(r'^did:(?:plc:[a-z2-7]{24}|web:[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?)$');
  static final RegExp rkeyPattern = RegExp(r'^[2-7a-z]{13}$');

  static BlueskyPostRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!_hosts.contains(url.host.toLowerCase())) return null;

    final List<String> raw;
    try {
      raw = url.pathSegments;
    } on FormatException {
      return null; // `%FF` and other undecodable bytes: not a post URL
    }
    var segments = raw;
    if (segments.isNotEmpty && segments.last.isEmpty) segments = segments.sublist(0, segments.length - 1);
    if (segments.length != 4 || segments[0] != 'profile' || segments[2] != 'post') return null;

    final actor = segments[1];
    final rkey = segments[3];
    if (!rkeyPattern.hasMatch(rkey)) return null;
    if (didPattern.hasMatch(actor)) return BlueskyPostRef(actor: actor, rkey: rkey);
    if (actor.length <= 253 && handlePattern.hasMatch(actor)) {
      return BlueskyPostRef(actor: actor.toLowerCase(), rkey: rkey);
    }
    return null;
  }
}
