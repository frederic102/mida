import '../media_models.dart';

typedef OdyseeClaimInfo = ({
  String name,
  String claimId,
  String sdHash,
  String title,
  String? author,
  String? thumbnailUrl,
  Duration? duration,
  int? width,
  int? height,
});

/// Pure JSON -> [OdyseeClaimInfo] mapping for a response from Odysee's
/// public JSON-RPC claim resolver
/// (`api.na-backend.odysee.com/api/v1/proxy?m=resolve`, `method: "resolve"`
/// - the same backend Odysee's own web player calls to turn a
/// `lbry://<channel>#<id>/<name>#<id>` URL into the claim record that
/// carries the video's actual source (`source.sd_hash`) and metadata).
/// Kept free of any I/O so it can be exercised entirely against
/// `test/fixtures/odysee_resolve.json` (captured live 2026-09-05,
/// `docs/plan-phase5-coverage.md` Lane D follow-up, from the real
/// `@lbry:3f/odysee:7` claim).
class OdyseeResolveParser {
  const OdyseeResolveParser();

  /// Throws [MediaExtractionException] (`NOT_FOUND`) when the result for
  /// [lbryUrl] is missing or is itself an `{"error": {...}}` object (the
  /// resolver's own way of saying the claim does not exist), and
  /// (`UNSUPPORTED_MEDIA`) when the claim resolves but is not a
  /// video/audio stream (e.g. a channel or a text post - no
  /// `value.source`).
  OdyseeClaimInfo parse(Map<String, dynamic> json, {required String lbryUrl}) {
    final result = json['result'];
    final entry = result is Map ? result[lbryUrl] : null;

    if (entry is! Map || entry['error'] != null) {
      throw const MediaExtractionException(
        'NOT_FOUND',
        'This Odysee content no longer exists or the link is wrong.',
      );
    }

    final value = entry['value'];
    final source = value is Map ? value['source'] : null;
    final sdHash = source is Map ? source['sd_hash'] as String? : null;
    final claimId = entry['claim_id'] as String?;
    final name = entry['name'] as String?;
    if (sdHash == null || claimId == null || name == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Odysee claim has no playable video/audio source (it may be '
            'a channel, image, or text post).',
      );
    }

    final signingChannel = entry['signing_channel'];
    final video = value is Map ? value['video'] : null;
    final durationSeconds = video is Map ? video['duration'] : null;

    return (
      name: name,
      claimId: claimId,
      sdHash: sdHash,
      title: value is Map ? (value['title'] as String? ?? 'Untitled') : 'Untitled',
      author: signingChannel is Map ? signingChannel['name'] as String? : null,
      thumbnailUrl: _thumbnailUrl(value is Map ? value['thumbnail'] : null),
      duration: durationSeconds is int ? Duration(seconds: durationSeconds) : null,
      width: video is Map ? _asInt(video['width']) : null,
      height: video is Map ? _asInt(video['height']) : null,
    );
  }

  String? _thumbnailUrl(dynamic thumbnail) => thumbnail is Map ? thumbnail['url'] as String? : null;

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}
