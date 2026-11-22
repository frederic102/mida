import 'package:flutter/material.dart';
import '../../../core/extractors/youtube/youtube_list_models.dart';
import '../../../core/utils/display_text.dart';
import '../services/channel_list_controller.dart';
import 'download_error_panel.dart';
import 'list_error_mapping.dart';

/// The videos of a pasted channel or playlist: tick some, then add them to
/// the queue. Hidden while the URL field holds no channel or playlist link.
class ChannelListCard extends StatelessWidget {
  const ChannelListCard({
    super.key,
    required this.controller,
    required this.onAdd,
  });

  final ChannelListController controller;

  /// Gets the chosen videos, in list order.
  final void Function(List<YoutubeListItem> chosen) onAdd;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.phase == ChannelListPhase.idle) return const SizedBox.shrink();
        final text = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 24), // the gap below, so a hidden card leaves none
          child: Card(
            key: const ValueKey('channel-list-card'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_heading(), style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (controller.ignoredUrls.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Only the first list is loaded. Not loaded: '
                      '${controller.ignoredUrls.map((u) => displayText(u)).join(', ')}. '
                      'Remove the first link from the field to load the next one.',
                      key: const ValueKey('channel-list-ignored'),
                      style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 12),
                  ..._body(context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _heading() {
    final listing = controller.listing;
    if (listing == null) return 'Channel or playlist';
    final what = listing.kind == YoutubeListKind.channel ? 'Channel' : 'Playlist';
    final title = displayText(listing.title);
    return title.isEmpty ? what : '$what: $title';
  }

  List<Widget> _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    switch (controller.phase) {
      case ChannelListPhase.idle:
        return const [];
      case ChannelListPhase.loading:
        return [
          const LinearProgressIndicator(key: ValueKey('channel-list-loading')),
          const SizedBox(height: 8),
          Text('Loading the video list...', style: muted),
        ];
      case ChannelListPhase.error:
        return [
          DownloadErrorPanel(
            error: describeListError(controller.error!),
            onRetry: controller.retry,
          ),
        ];
      case ChannelListPhase.loaded:
        return _loaded(context, muted);
    }
  }

  List<Widget> _loaded(BuildContext context, TextStyle? muted) {
    final listing = controller.listing!;
    final count = controller.selectedCount;
    if (listing.items.isEmpty) return [Text('This list has no public videos.', style: muted)];
    return [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(onPressed: controller.selectAll, child: const Text('Select all')),
          TextButton(onPressed: controller.selectNone, child: const Text('Select none')),
          Text('$count of ${listing.items.length} selected', key: const ValueKey('channel-list-count'), style: muted),
        ],
      ),
      if (listing.truncated)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Showing the first ${listing.items.length} videos. This list has more; add these first, '
            'or use mida-cli list with a higher --limit.',
            key: const ValueKey('channel-list-truncated'),
            style: muted,
          ),
        ),
      const SizedBox(height: 8),
      SizedBox(
        height: 320,
        child: ListView.builder(
          itemCount: listing.items.length,
          itemBuilder: (context, i) {
            final item = listing.items[i];
            return CheckboxListTile(
              key: ValueKey('channel-item-${item.id}'),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: controller.isSelected(item.id),
              onChanged: (_) => controller.toggle(item.id),
              title: Text(displayText(item.title).isEmpty ? item.id : displayText(item.title), maxLines: 2, overflow: TextOverflow.ellipsis),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('channel-add-to-queue'),
        onPressed: count > 0 ? () => onAdd(controller.selectedItems) : null,
        icon: const Icon(Icons.playlist_add),
        label: Text(count == 1 ? 'Add 1 to queue' : 'Add $count to queue'),
      ),
    ];
  }
}
