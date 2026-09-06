import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// [NiconicoDmcSessionClient.startSession]'s result: the playable stream
/// URL plus whatever cookies the session-create response itself set (see
/// that class's doc), grouped by domain the same shape
/// [MediaInfo.cookiesByDomain] uses so [NiconicoExtractor] can pass this
/// straight through without reshaping it.
typedef NiconicoSessionResult = ({
  String contentUri,
  Map<String, List<CookieEntry>> cookiesByDomain,
});

/// Starts a Niconico DMC/DMS playback session
/// (`POST api.dmc.nico/api/sessions?_format=json`) from the `session_api`
/// object [NiconicoWatchDataParser] reads out of the watch page, and
/// returns the `content_uri` (an HLS or MP4 URL) the response carries.
///
/// Best-effort, not live-confirmed (`docs/plan-phase5-coverage.md` Lane D
/// report - see `NiconicoWatchDataParser`'s doc for why: the legacy page
/// shape this reads from was not observed on the current live site within
/// this pass's budget). The request body shape here matches the
/// long-documented DMC session contract; field names/required nesting
/// may have drifted since - flagged as the lowest-confidence piece of
/// this pass's Niconico support, a priority follow-up once the current
/// site's `nvapi.nicovideo.jp` auth requirement is understood.
///
/// Deliberately does not implement the periodic heartbeat POST a DMC
/// session needs to stay alive for a long download (`heartbeat_lifetime`
/// in the response, typically ~2 minutes) - out of scope for a first
/// pass; a short clip download can finish inside one lifetime window, a
/// long one currently cannot and needs that follow-up.
///
/// `docs/plan-phase6-av-pairing.md` Lane N (N2): the delivery CDN
/// (`delivery.domand.nicovideo.jp` for the current site) gates its media
/// playlists on a session cookie separate from the DMC token/signature
/// pair - if the session-create response carries one (`Set-Cookie`), it
/// must ride along on every later request to that CDN or the media
/// playlist 403s even though the master opened fine. [startSession]
/// therefore returns whatever cookies the response actually set,
/// grouped by each cookie's own `Domain` attribute (falling back to the
/// request host when a cookie omits `Domain`, per RFC 6265) - never
/// fabricated, only what our own client received.
///
/// **Scope: this class is Niconico-only, and so is its cookie hygiene.**
/// The `Domain`-attribute vetting below ([_knownPublicSuffixes],
/// [requireThreeLabelDomains], [_domainMatches]) is a deliberately small,
/// non-exhaustive guard sized for one extractor talking to one operator's
/// own domains - it is not, and must not be reused as, a general-purpose
/// public-suffix implementation for other extractors or for the shared
/// `lib/core/net/` layer. Anything needing that should pull in a real
/// Public Suffix List rather than widen this set (phase 6 round 3,
/// S-R3-5).
class NiconicoDmcSessionClient {
  final HttpClient Function() _httpClientFactory;

  /// Rewrites the session-create endpoint URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _requestUrlBuilder;

  NiconicoDmcSessionClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(Uri url)? requestUrlBuilder,
    this.requireThreeLabelDomains = false,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _requestUrlBuilder = requestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static const _defaultEndpoint = 'https://api.dmc.nico/api/sessions?_format=json';

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when
  /// [sessionApi] is missing a field this needs to build a request at
  /// all, and (`NETWORK`/`PARSE_ERROR`) for transport/decode failures.
  /// See the class doc for why the result also carries [cookiesByDomain].
  Future<NiconicoSessionResult> startSession(Map<String, dynamic> sessionApi) async {
    final videos = sessionApi['videos'];
    final audios = sessionApi['audios'];
    final contentId = sessionApi['contentId'] ?? sessionApi['content_id'];
    final token = sessionApi['token'];
    final signature = sessionApi['signature'];
    if (videos is! List || videos.isEmpty || contentId == null || token == null || signature == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Niconico video\'s session data is missing fields MiDa needs '
            'to start playback.',
      );
    }

    final requestBody = {
      'session': {
        'recipe_id': sessionApi['recipeId'] ?? sessionApi['recipe_id'],
        'content_id': contentId,
        'content_type': 'movie',
        'content_src_id_sets': [
          {
            'content_src_ids': [
              {
                'src_id_to_mux': {
                  'video_src_ids': videos,
                  'audio_src_ids': audios is List ? audios : const [],
                },
              },
            ],
          },
        ],
        'timing_constraint': 'unlimited',
        'keep_method': {
          'heartbeat': {'lifetime': sessionApi['heartbeatLifetime'] ?? sessionApi['heartbeat_lifetime'] ?? 120000},
        },
        'protocol': {
          'name': 'http',
          'parameters': {
            'http_parameters': {
              'parameters': {
                'http_output_download_parameters': {
                  'use_well_known_port': 'yes',
                  'use_ssl': 'yes',
                },
              },
            },
          },
        },
        'content_uri': '',
        'session_operation_auth': {
          'session_operation_auth_by_signature': {'token': token, 'signature': signature},
        },
        'content_auth': {
          'auth_types': {'http': 'ht2'},
          'service_id': 'nicovideo',
          'service_user_id': sessionApi['serviceUserId'] ?? sessionApi['service_user_id'] ?? '',
        },
        'client_info': {'player_id': sessionApi['playerId'] ?? sessionApi['player_id'] ?? ''},
        'priority': sessionApi['priority'] ?? 0,
      },
    };

    final requestUrl = _requestUrlBuilder(Uri.parse(_defaultEndpoint));
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.postUrl(requestUrl);
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode(requestBody)));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw MediaExtractionException(
          'NETWORK',
          'Niconico returned HTTP ${response.statusCode} while starting playback.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Niconico returned a response MiDa could not read as JSON.',
        );
      }

      final responseData = json['data'];
      final session = responseData is Map ? responseData['session'] : null;
      final contentUri = session is Map ? session['content_uri'] as String? : null;
      if (contentUri == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Niconico did not return a playable stream URL for this session.',
        );
      }
      return (
        contentUri: contentUri,
        cookiesByDomain: _cookiesByDomain(response.cookies, requestUrl.host),
      );
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Groups [cookies] (as dart:io already parsed them out of every
  /// `Set-Cookie` header on the response) by each cookie's own `Domain`
  /// attribute, falling back to [fallbackHost] (the request's own host)
  /// when a cookie omits `Domain` entirely - per RFC 6265 a cookie with no
  /// `Domain` attribute is host-only, scoped to the exact host that set
  /// it. A cookie with an empty name is skipped (malformed `Set-Cookie`),
  /// never a throw: this must not turn a successful session start into a
  /// failure just because one cookie header was unparseable.
  ///
  /// Phase 6 round 2 (S-R6, Bulwark#1/Codex#16): a cookie that *does*
  /// carry a `Domain` attribute is only kept when that domain
  /// domain-matches [fallbackHost] (see [_domainMatches]) - dropped
  /// entirely otherwise. Without this, a compromised or misbehaving
  /// response from one host (this session-create endpoint) could set
  /// `Domain=<some other host or CDN>` and have that cookie ride along on
  /// every later request to that unrelated host, since `CookieScope`
  /// downstream trusts whatever domain a cookie in `cookiesByDomain` is
  /// filed under.
  ///
  /// Phase 6 round 3 (S-R3-1, Codex #7): the *key* shape matters as much
  /// as the filtering. A cookie with a `Domain` attribute is filed under
  /// `'.<domain>'` (leading dot) and a cookie without one under the bare
  /// host - the exact convention `CookieScope.headerFor` documents and
  /// reads. Round 2 filed both bare, which made every captured domain
  /// cookie behave as host-only downstream.
  Map<String, List<CookieEntry>> _cookiesByDomain(List<Cookie> cookies, String fallbackHost) {
    final grouped = <String, List<CookieEntry>>{};
    for (final cookie in cookies) {
      if (cookie.name.isEmpty) continue;
      final rawDomain = cookie.domain;
      String key;
      if (rawDomain == null || rawDomain.isEmpty) {
        // Host-only cookie (no `Domain` attribute at all): filed under the
        // bare host, which is exactly how `CookieScope` reads "exact host
        // only, never a subdomain".
        key = fallbackHost.toLowerCase();
        if (key.isEmpty) continue;
      } else {
        final candidate = (rawDomain.startsWith('.') ? rawDomain.substring(1) : rawDomain).toLowerCase();
        if (!_domainMatches(candidate, fallbackHost)) continue;
        // Phase 6 round 3 (S-R3-1, Codex #7): a cookie that *did* carry a
        // `Domain` attribute must be filed under a leading-dot key.
        // `CookieScope.headerFor` uses that leading dot as the sole
        // signal for "domain cookie, so it also reaches every subdomain
        // of this domain"; filing it bare (what round 2 did) demoted
        // every domain cookie to host-only, so the very cookie this
        // client exists to capture - the domand session cookie set with
        // `Domain=nicovideo.jp` by `api.dmc.nicovideo.jp` - was silently
        // dropped from requests to the sibling delivery CDN, and the
        // media playlist 403s exactly as it did before N2.
        key = '.$candidate';
      }
      grouped.putIfAbsent(key, () => []).add(CookieEntry(
            domain: key,
            path: cookie.path ?? '/',
            secure: cookie.secure,
            name: cookie.name,
            value: cookie.value,
          ));
    }
    return grouped;
  }

  /// A small, deliberately non-exhaustive set of multi-label public
  /// suffixes that must still be rejected as a `Domain` value even though
  /// they clear the "at least two labels" bar below - `Domain=co.jp`
  /// would otherwise scope a cookie to every `*.co.jp` site, not just the
  /// one host that actually set it. This is not a full Public Suffix List
  /// (deliberately - pulling one in for a single extractor's cookie
  /// hygiene is its own maintenance burden); phase 6 round 3 (S-R3-5,
  /// Codex #8) widened it from the Japanese ccTLD categories relevant to
  /// niconico's own domain space to the common two-label registry
  /// suffixes (`co.uk`, `com.au`, ...) and the private suffixes where
  /// every tenant gets a label of their own (`github.io`,
  /// `herokuapp.com`, ...). It is still not exhaustive, which is why
  /// [requireThreeLabelDomains] exists as a blunter alternative.
  static const _knownPublicSuffixes = {
    // Bare gTLDs / ccTLDs worth naming even though the label count check
    // below already rejects them.
    'com', 'net', 'org', 'jp', 'uk', 'au', 'io', 'br', 'in', 'kr', 'cn',
    // Japanese second-level categories (niconico's own domain space).
    'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'ad.jp', 'go.jp', 'gr.jp', 'ed.jp', 'lg.jp',
    // Other common two-label registry suffixes an attacker-supplied
    // `Domain` could otherwise use to span a whole registrar's namespace.
    'co.uk', 'org.uk', 'me.uk', 'ac.uk', 'gov.uk', 'net.uk', 'sch.uk',
    'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au', 'id.au',
    'co.kr', 'or.kr', 'ne.kr', 'go.kr', 're.kr', 'pe.kr',
    'com.br', 'net.br', 'org.br',
    'co.in', 'net.in', 'org.in', 'firm.in',
    'com.cn', 'net.cn', 'org.cn', 'gov.cn',
    'co.nz', 'net.nz', 'org.nz',
    'com.hk', 'org.hk', 'idv.hk',
    'com.tw', 'org.tw', 'idv.tw',
    'com.sg', 'com.mx', 'com.ar', 'co.za', 'co.il', 'co.id', 'co.th', 'or.th',
    // Private suffixes: every customer of these gets their own label
    // under them, so a `Domain` of the suffix itself spans all of them.
    'github.io', 'gitlab.io', 'herokuapp.com', 'herokussl.com',
    'appspot.com', 'cloudfront.net', 'azurewebsites.net', 'cloudapp.net',
    'netlify.app', 'vercel.app', 'pages.dev', 'workers.dev', 'web.app',
    'firebaseapp.com', 's3.amazonaws.com', 'blogspot.com', 'r2.dev',
  };

  /// Opt-in tightening (phase 6 round 3, S-R3-5, Codex #8): when true, a
  /// `Domain` value must carry at least three labels
  /// (`delivery.domand.nicovideo.jp`, `nicovideo.jp` -> rejected) on top
  /// of every check below. Off by default because it is strictly stronger
  /// than what RFC 6265 permits and would reject legitimate two-label
  /// registrable domains; it exists so a caller operating exclusively
  /// against niconico's own three-plus-label hosts can refuse anything
  /// broader without depending on [_knownPublicSuffixes] being complete
  /// (it deliberately is not - see its doc).
  final bool requireThreeLabelDomains;

  /// RFC 6265 domain-match (a cookie's `Domain` is honored for the exact
  /// host that set it, or any subdomain of it), hardened against a
  /// `Domain` value that is - or resolves to - a bare public suffix:
  /// [cookieDomain] must have at least two labels and not itself be one
  /// of [_knownPublicSuffixes], on top of the ordinary suffix check
  /// ([host] equals [cookieDomain], or ends with `.$cookieDomain`).
  /// Without the label/suffix checks, `Domain=jp` (one label) or
  /// `Domain=co.jp` (two labels, but still a public suffix) would each
  /// legitimately domain-match `delivery.domand.nicovideo.jp` under the
  /// suffix rule alone.
  bool _domainMatches(String cookieDomain, String host) {
    final domain = cookieDomain.toLowerCase();
    final normalizedHost = host.toLowerCase();
    if (domain.isEmpty) return false;

    final labelCount = domain.split('.').where((label) => label.isNotEmpty).length;
    if (labelCount < 2) return false; // bare TLD, e.g. "com", "jp"
    if (requireThreeLabelDomains && labelCount < 3) return false;
    if (_knownPublicSuffixes.contains(domain)) return false;

    return normalizedHost == domain || normalizedHost.endsWith('.$domain');
  }
}
