import 'extractor_site_ids.dart';
import 'media_models.dart';

/// The two cross-cutting rewrites `ExtractorRegistry` applies to every
/// successful extraction ([by] is the extractor that produced [info]):
///
///  1. Protocol normalization: a format's `container` implies how it must be
///     downloaded (`m3u8` needs ffmpeg, not a ranged GET), so extractors leave
///     `MediaFormat.protocol` at its default and this derives the real value.
///  2. Provenance: `MediaInfo.extractor` is set to [by]'s site id, or cleared
///     to null when [by] is outside `extractor_site_ids.dart`. Whatever the
///     extractor put in that field itself is never passed through, so the CLI
///     `extractor` value always comes from our own table.
MediaInfo normalizeAndStamp(MediaInfo info, Object by) {
  final needsChange = info.formats.any((f) => f.protocol != _protocolFor(f.container));
  final id = extractorSiteId(by);
  return info.copyWith(
    extractor: id,
    clearExtractor: id == null,
    formats: needsChange ? [for (final f in info.formats) f.withProtocol(_protocolFor(f.container))] : null,
  );
}

String _protocolFor(String container) {
  switch (container) {
    case 'm3u8':
      return 'hls';
    case 'mpd':
      return 'dash';
    default:
      return 'https';
  }
}
