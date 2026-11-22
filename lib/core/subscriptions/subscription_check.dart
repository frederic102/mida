import '../extractors/media_models.dart';
import '../extractors/youtube/youtube_list_models.dart';
import '../extractors/youtube/youtube_list_target.dart';
import '../extractors/youtube/youtube_lister.dart';
import 'download_archive.dart';
import 'subscription.dart';

/// Result of checking one subscription: [updated] carries the resolved
/// channel id and the new `lastChecked`; [fresh] are the uploads to queue.
class SubscriptionCheck {
  final Subscription updated;
  final List<YoutubeListItem> fresh;

  const SubscriptionCheck(this.updated, this.fresh);
}

/// Reads the channel's latest uploads (RSS) and keeps those published after
/// the subscription was created and not yet in [archive]. Throws a
/// `MediaExtractionException` when the source is not a channel or the feed
/// cannot be read; the caller then leaves `lastChecked` untouched.
Future<SubscriptionCheck> checkSubscription(
  YoutubeLister lister,
  Subscription subscription,
  DownloadArchive archive, {
  DateTime? now,
}) async {
  var id = subscription.channelId;
  var title = subscription.title;
  if (id == null) {
    final raw = subscription.source.trim();
    final target = YoutubeListTarget.parse(raw);
    if (RegExp(r'^UC[A-Za-z0-9_-]{22}$').hasMatch(raw)) {
      id = raw;
    } else if (target != null && target.kind == YoutubeListKind.channel) {
      id = target.channelId;
      if (id == null) {
        final listing = await lister.list(target, maxItems: 1);
        id = listing.id;
        if (title.isEmpty) title = listing.title;
      }
    }
  }
  if (id == null) throw const MediaExtractionException('UNSUPPORTED_URL', 'The subscription is not a YouTube channel.');
  final latest = await lister.latestUploads(id);
  return SubscriptionCheck(
    subscription.copyWith(channelId: id, title: title, lastChecked: now ?? DateTime.now().toUtc()),
    newUploadsSince(latest, createdAt: subscription.createdAt, archive: archive),
  );
}
