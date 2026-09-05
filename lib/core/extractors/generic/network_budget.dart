/// A shared, mutable fetch counter for one `GenericExtractor.extract()`
/// call's "follow embedded players" step (iframes + oEmbed): per the
/// coordinator's Lane B security follow-up, these must draw from one
/// combined pool of at most [maxFetches] outbound HTTP requests, not an
/// independent cap per source. `IframeFollower` already caps how many
/// iframe/embed/`og:video:url` *candidates* it will even return
/// ([IframeFollower.maxCandidates]), but that cap said nothing about the
/// oEmbed JSON fetch, or the extra iframe fetch that JSON can itself point
/// at - both of which used to run unconditionally on top of the iframe
/// candidates, with no shared ceiling across the two sources.
///
/// Every outbound fetch this step makes (each embed-candidate GET, the
/// oEmbed JSON GET, and the GET for the iframe an oEmbed response points
/// at) must call [tryConsume] first and skip the fetch entirely if it
/// returns false.
class NetworkBudget {
  final int maxFetches;
  int _consumed = 0;

  NetworkBudget({this.maxFetches = 6});

  /// True (and decrements the remaining budget) if a fetch may still be
  /// made; false (budget left untouched) once [maxFetches] have already
  /// been consumed. Callers must check this *before* making the fetch it
  /// guards, and must not make that fetch at all when it returns false.
  bool tryConsume() {
    if (_consumed >= maxFetches) return false;
    _consumed++;
    return true;
  }

  int get remaining => maxFetches - _consumed;
  int get consumed => _consumed;
}
