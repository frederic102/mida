import '../../media_models.dart';
import '../network_budget.dart';
import '../stage_deadline.dart';
import 'brightcove.dart';
import 'embed_delegation.dart';
import 'embed_http.dart';
import 'embed_resolver.dart';
import 'jw_platform.dart';
import 'kaltura.dart';
import 'wistia.dart';

/// The generic extractor's embed-platform step: runs when the page scan
/// found no usable media, before the iframe/oEmbed follow when a resolver
/// [claims] the page (so a delegation or platform API is never shadowed by
/// a generic sniff of the player page), after it otherwise. Recognizes embedded
/// players from known platform families and resolves them through each
/// platform's own public player API ([EmbedResolver]s), or hands a
/// YouTube/Vimeo/Dailymotion embed back to its native extractor via
/// [EmbedDelegationException].
///
/// Outcome priority across every matching resolver (each tried at most
/// once, in [resolvers] order, all sharing one [NetworkBudget]):
///   1. the first resolver that returns a [MediaInfo] with formats: returned;
///   2. else a delegation, if any resolver raised one: thrown;
///   3. else `DRM_PROTECTED`, if any resolver reported only protected
///      renditions: thrown;
///   4. else null (the caller keeps its normal `NO_MEDIA_FOUND` path).
/// Any other failure of one resolver (network, HTTP error, budget spent,
/// malformed JSON, a host-policy refusal, even a throwing [EmbedResolver.matches])
/// only skips that resolver: this step is a bonus discovery path and must
/// never make extraction worse. The one exception is the caller's
/// [StageDeadline] running out: that ends the whole pass at once
/// ([StageDeadlineExceeded] is rethrown, no further resolver is tried).
///
/// Registry wiring for delegation (lead-owned, not done here): see
/// [EmbedDelegationException]; until it exists the exception behaves as
/// a plain `NO_MEDIA_FOUND`.
class EmbedResolverChain {
  final EmbedHttp http;
  final List<EmbedResolver> resolvers;

  /// Total outbound requests one [resolve] pass may make. Brightcove
  /// needs 2, the others 1, so this covers several families on one page.
  final int maxFetches;

  const EmbedResolverChain({
    required this.http,
    this.resolvers = defaultResolvers,
    this.maxFetches = 6,
  });

  static const List<EmbedResolver> defaultResolvers = [
    BrightcoveEmbedResolver(),
    KalturaEmbedResolver(),
    WistiaEmbedResolver(),
    JwPlatformEmbedResolver(),
    DelegatingEmbedResolver(),
  ];

  /// True when at least one resolver recognizes an embed on [html]
  /// (network-free; a throwing [EmbedResolver.matches] counts as no).
  bool claims(String html) => resolvers.any((resolver) => _safeMatches(resolver, html));

  Future<MediaInfo?> resolve({required Uri pageUrl, required String html, StageDeadline? deadline}) async {
    final request = EmbedRequest(
      pageUrl: pageUrl,
      html: html,
      http: BudgetedEmbedHttp(http, NetworkBudget(maxFetches: maxFetches), deadline: deadline),
    );

    EmbedDelegationException? delegation;
    MediaExtractionException? drm;
    for (final resolver in resolvers) {
      deadline?.ensureActive();
      try {
        if (!resolver.matches(html)) continue;
        final info = await resolver.resolve(request);
        if (info != null && info.formats.isNotEmpty) return info;
      } on StageDeadlineExceeded {
        rethrow;
      } on EmbedDelegationException catch (e) {
        delegation ??= e;
      } on MediaExtractionException catch (e) {
        if (e.status == 'DRM_PROTECTED') drm ??= e;
      } catch (_) {
        // Per-resolver failure isolation; see class doc.
      }
    }
    if (delegation != null) throw delegation;
    if (drm != null) throw drm;
    return null;
  }

  static bool _safeMatches(EmbedResolver resolver, String html) {
    try {
      return resolver.matches(html);
    } catch (_) {
      return false;
    }
  }
}
