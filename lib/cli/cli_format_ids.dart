import '../core/extractors/media_models.dart';
import '../core/utils/url_parser.dart';

/// The ids `resolve` prints and `download --format-id` accepts: one per
/// format, in the same order, unique and free of secrets.
///
/// An extractor's own id is kept when it is short, plain text and unique
/// (`muxed-720`, `hls-1080`). Otherwise, for example when the id is a
/// signed media URL or two formats share an id, the format is called
/// `fmt-<index>`, its position in the extractor's list. Index ids are
/// stable as long as the source lists its formats in the same order, which
/// every extractor here does for the same page. Both commands compute the
/// ids with this one function, so an id copied from `resolve` always means
/// the same format in `download`.
List<String> formatSelectionIds(List<MediaFormat> formats) {
  final counts = <String, int>{};
  for (final f in formats) {
    counts[f.id] = (counts[f.id] ?? 0) + 1;
  }
  return [
    for (var i = 0; i < formats.length; i++)
      _isPlain(formats[i].id) && counts[formats[i].id] == 1 ? formats[i].id : 'fmt-$i',
  ];
}

final _indexId = RegExp(r'^fmt-\d+$');
final _plain = RegExp(r'^[A-Za-z0-9._+-]{1,64}$');

/// Plain: letters, digits, `. _ + -`, at most 64 characters, not shaped
/// like an index id, and unchanged by URL redaction.
bool _isPlain(String id) =>
    _plain.hasMatch(id) && !_indexId.hasMatch(id) && UrlParser.redactUrlsInText(id) == id;
