import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/extractors/youtube/youtube_list_models.dart';
import '../../../core/extractors/youtube/youtube_lister.dart';
import '../services/channel_list_controller.dart';
import '../services/download_queue_service.dart';
import '../services/download_service.dart';
import '../widgets/channel_list_card.dart';
import '../widgets/download_action_button.dart';
import '../widgets/download_options_card.dart';
import '../widgets/download_queue_card.dart';
import '../widgets/download_type_selector.dart';
import '../widgets/download_url_input_card.dart';
import 'url_batch.dart';

class DownloadScreen extends StatefulWidget {
  /// [lister] and [listDebounce] exist for tests; the app uses the defaults.
  const DownloadScreen({super.key, this.lister, this.listDebounce = const Duration(milliseconds: 500)});

  final YoutubeLister? lister;
  final Duration listDebounce;

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;
  late final ChannelListController _list;

  UrlBatch _batch = UrlBatch.empty;
  DownloadType _selectedType = DownloadType.video;
  VideoQuality _selectedVideoQuality = VideoQuality.best;
  VideoFormat _selectedVideoFormat = VideoFormat.mp4;
  AudioQuality _selectedAudioQuality = AudioQuality.best;
  AudioFormat _selectedAudioFormat = AudioFormat.mp3;
  SubtitleOption _selectedSubtitle = SubtitleOption.none;

  /// Last clipboard text seen on focus, the text the user dismissed, and
  /// the links currently offered by the chip (null = chip hidden).
  String? _clipboardText;
  String? _dismissedClipboardText;
  List<String>? _suggestion;

  @override
  void initState() {
    super.initState();
    _list = ChannelListController(widget.lister ?? YoutubeLister(), debounce: widget.listDebounce);
    // Window focus on desktop arrives as a resume; also check once on open.
    _lifecycle = AppLifecycleListener(onResume: _checkClipboard);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _list.dispose();
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<String?> _readClipboard() async {
    try {
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _checkClipboard() async {
    final text = await _readClipboard();
    if (!mounted) return;
    _clipboardText = text;
    _refreshSuggestion();
  }

  void _refreshSuggestion() {
    final next = clipboardSuggestion(
      clipboardText: _clipboardText,
      queuedUrls: context.read<DownloadQueueService>().knownUrls,
      fieldText: _urlController.text,
      dismissedText: _dismissedClipboardText,
    );
    setState(() => _suggestion = next);
  }

  void _onUrlChanged(String value) {
    _batch = UrlBatch.parse(value);
    _list.updateUrls(_batch.urls);
    _refreshSuggestion();
  }

  /// Links that are plain videos; channel and playlist links go to the list card.
  List<String> get _directUrls => [for (final u in _batch.urls) if (listTargetOf(u) == null) u];

  DownloadOptions get _options => DownloadOptions(
        videoQuality: _selectedVideoQuality,
        videoFormat: _selectedVideoFormat,
        audioQuality: _selectedAudioQuality,
        audioFormat: _selectedAudioFormat,
        subtitleOption: _selectedSubtitle,
      );

  void _notifySkipped(int skipped) {
    if (skipped <= 0) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(skipped == 1
          ? '1 link was already waiting in the queue, so it was not added twice.'
          : '$skipped links were already waiting in the queue, so they were not added twice.'),
    ));
  }

  void _addChosen(List<YoutubeListItem> chosen) {
    final added = context.read<DownloadQueueService>().enqueueAll(
          [for (final i in chosen) i.url.toString()],
          type: _selectedType,
          options: _options,
        );
    _list.selectNone();
    _notifySkipped(chosen.length - added);
  }

  /// Appends [text] on its own line; never starts a download.
  void _appendToField(String text) {
    final current = _urlController.text.trimRight();
    final joined = current.isEmpty ? text.trim() : '$current\n${text.trim()}';
    _urlController.value = TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
    _onUrlChanged(joined);
    _urlFocus.requestFocus();
  }

  Future<void> _pasteFromClipboard() async {
    final text = await _readClipboard();
    if (!mounted || text == null || text.trim().isEmpty) return;
    _appendToField(text);
  }

  void _acceptSuggestion() {
    final urls = _suggestion;
    if (urls == null) return;
    _appendToField(urls.join('\n'));
  }

  void _dismissSuggestion() {
    _dismissedClipboardText = _clipboardText;
    _refreshSuggestion();
  }

  void _clearField() {
    _urlController.clear();
    _onUrlChanged('');
  }

  void _start() {
    final direct = _directUrls;
    if (direct.isEmpty) return;
    final added = context.read<DownloadQueueService>().enqueueAll(direct, type: _selectedType, options: _options);
    // A channel or playlist link stays in the field: its list is still on screen.
    final listLinks = [for (final u in _batch.urls) if (listTargetOf(u) != null) u];
    _urlController.text = listLinks.join('\n');
    _onUrlChanged(_urlController.text);
    _notifySkipped(direct.length - added);
  }

  @override
  Widget build(BuildContext context) {
    final queueBusy = context.select<DownloadQueueService, bool>((q) => q.isBusy);

    return Scaffold(
      appBar: AppBar(title: const Text('Download')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DownloadUrlInputCard(
              controller: _urlController,
              focusNode: _urlFocus,
              batch: _batch,
              onChanged: _onUrlChanged,
              onPaste: _pasteFromClipboard,
              onClear: _clearField,
              onSubmit: _start,
              suggestion: _suggestion,
              onAcceptSuggestion: _acceptSuggestion,
              onDismissSuggestion: _dismissSuggestion,
            ),
            ChannelListCard(controller: _list, onAdd: _addChosen),
            DownloadTypeSelectorCard(
              selectedType: _selectedType,
              onTypeSelected: (type) => setState(() => _selectedType = type),
            ),
            const SizedBox(height: 24),
            DownloadOptionsCard(
              selectedType: _selectedType,
              selectedVideoQuality: _selectedVideoQuality,
              selectedVideoFormat: _selectedVideoFormat,
              selectedSubtitle: _selectedSubtitle,
              selectedAudioQuality: _selectedAudioQuality,
              selectedAudioFormat: _selectedAudioFormat,
              onVideoQualityChanged: (v) => setState(() => _selectedVideoQuality = v),
              onVideoFormatChanged: (v) => setState(() => _selectedVideoFormat = v),
              onSubtitleChanged: (v) => setState(() => _selectedSubtitle = v),
              onAudioQualityChanged: (v) => setState(() => _selectedAudioQuality = v),
              onAudioFormatChanged: (v) => setState(() => _selectedAudioFormat = v),
            ),
            const SizedBox(height: 24),
            DownloadActionButton(
              linkCount: _directUrls.length,
              queueBusy: queueBusy,
              onPressed: _start,
            ),
            const SizedBox(height: 24),
            const DownloadQueueCard(),
          ],
        ),
      ),
    );
  }
}
