import '../features/download/models/download_models.dart';

/// Raised for any command-line mistake. Always exit code 2.
class CliUsageError implements Exception {
  final String code;
  final String message;

  const CliUsageError(this.message, {this.code = 'USAGE'});

  @override
  String toString() => message;
}

/// A fully parsed and validated command line. Hand rolled on purpose: this
/// project adds zero pub packages (dependency minimalism is a hard rule).
class CliRequest {
  final String command;
  final String? url;
  final bool quiet;
  final bool headless;
  final bool loginSession;
  final bool captions;
  final String? outDir;
  final DownloadType type;
  final VideoQuality quality;
  final AudioFormat audioFormat;
  final AudioQuality audioQuality;
  final VideoFormat container;
  final SubtitleOption? subtitles;
  final String? formatId;
  final String? ffmpeg;

  /// Option names the user actually typed (without `--`), so the CLI can
  /// tell "left at the default" from "asked for" and warn on no-op combos.
  final Set<String> given;

  const CliRequest({
    required this.command,
    this.url,
    this.quiet = false,
    this.headless = false,
    this.loginSession = false,
    this.captions = false,
    this.outDir,
    this.type = DownloadType.video,
    this.quality = VideoQuality.best,
    this.audioFormat = AudioFormat.mp3,
    this.audioQuality = AudioQuality.best,
    this.container = VideoFormat.mp4,
    this.subtitles,
    this.formatId,
    this.ffmpeg,
    this.given = const {},
  });

  /// The [DownloadOptions] this request asks the pipeline for. `--subtitles`
  /// picks the languages; bare `--captions` means the GUI's widest choice
  /// (Korean + English).
  DownloadOptions get downloadOptions => DownloadOptions(
        videoQuality: quality,
        audioFormat: audioFormat,
        audioQuality: audioQuality,
        videoFormat: container,
        subtitleOption: subtitles ?? (captions ? SubtitleOption.koreanEnglish : SubtitleOption.none),
      );

  /// Human notes for options that cannot change this download.
  List<String> get noOpWarnings => [
        if (type == DownloadType.audio)
          for (final o in const ['quality', 'container', 'captions', 'subtitles'])
            if (given.contains(o)) '--$o has no effect with --type audio.',
        if (type == DownloadType.video)
          for (final o in const ['audio-format', 'audio-quality'])
            if (given.contains(o)) '--$o has no effect with --type video (it only applies to --type audio).',
        if (formatId != null && given.contains('quality')) '--quality is ignored because --format-id pins one format.',
      ];
}

/// One-line usage, also the `help` result.
const cliUsage = 'Usage: mida-cli <resolve|download|sites|version|help> [url] [options]. '
    'resolve <url> [--login-session] [--headless]; '
    'download <url> [--out DIR] [--type video|audio] [--quality best|2160|1440|1080|720|480|360] '
    '[--container mp4|webm|mkv] [--audio-format mp3|m4a|opus|flac|wav] [--audio-quality best|320|256|128] '
    '[--format-id ID] [--captions] [--subtitles ko|en|ko,en] [--login-session] [--headless] [--ffmpeg PATH]; '
    'every command accepts --quiet and --json (the default and only format), before or after the command. '
    'Quote the URL in single quotes in bash and PowerShell.';

const _valueOptions = {
  'out',
  'type',
  'quality',
  'container',
  'audio-format',
  'audio-quality',
  'subtitles',
  'format-id',
  'ffmpeg',
};
const _flagOptions = {'captions', 'login-session', 'headless', 'quiet', 'json'};
const _globalFlags = {'quiet', 'json'};

const _allowedOptions = <String, Set<String>>{
  'resolve': {'login-session', 'headless', 'quiet', 'json'},
  'download': {..._valueOptions, ..._flagOptions},
  'sites': _globalFlags,
  'version': _globalFlags,
  'help': _globalFlags,
};

const _helpFlags = {'--help', '-h'};

/// Parses [args] (without the program name). Throws [CliUsageError].
///
/// Help: the `help` command, or `--help` / `-h` where an option may stand
/// (before the command or among its options). The same text as an option
/// value (`--out help`, `--format-id -h`) or after `--` is data,
/// not a help request. Global flags (`--quiet`, `--json`) may come before
/// the command. Any option given twice, flag or value, before or after
/// the command, is refused.
CliRequest parseCliArgs(List<String> args) {
  final seen = <String>{};
  void once(String name) {
    if (!seen.add(name)) {
      throw CliUsageError('Option --$name was given more than once.', code: 'INVALID_VALUE');
    }
  }

  var start = 0;
  while (start < args.length) {
    final arg = args[start];
    if (_helpFlags.contains(arg)) return const CliRequest(command: 'help');
    final name = _flagName(arg);
    if (name == null || !_globalFlags.contains(name)) break;
    once(name);
    start++;
  }
  if (start >= args.length) throw const CliUsageError(cliUsage);
  final command = args[start];
  final allowed = _allowedOptions[command];
  if (allowed == null) throw CliUsageError('Unknown command "$command". $cliUsage');

  final positionals = <String>[];
  final flags = <String>{...seen};
  final values = <String, String>{};
  var rest = false;

  for (var i = start + 1; i < args.length; i++) {
    final arg = args[i];
    if (rest || !arg.startsWith('-')) {
      positionals.add(arg);
      continue;
    }
    if (arg == '--') {
      rest = true;
      continue;
    }
    if (_helpFlags.contains(arg)) return const CliRequest(command: 'help');
    if (!arg.startsWith('--')) throw CliUsageError('Unknown option "$arg". $cliUsage');
    final eq = arg.indexOf('=');
    final name = eq == -1 ? arg.substring(2) : arg.substring(2, eq);
    if (!allowed.contains(name)) {
      throw CliUsageError('Option --$name is not valid for "$command". $cliUsage');
    }
    once(name);
    if (_flagOptions.contains(name)) {
      if (eq != -1) throw CliUsageError('Option --$name does not take a value.');
      flags.add(name);
      continue;
    }
    String value;
    if (eq != -1) {
      value = arg.substring(eq + 1);
    } else {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw CliUsageError('Option --$name needs a value.');
      }
      value = args[++i];
    }
    if (value.isEmpty) throw CliUsageError('Option --$name needs a non-empty value.');
    values[name] = value;
  }

  final needsUrl = command == 'resolve' || command == 'download';
  if (needsUrl && positionals.length != 1) {
    throw CliUsageError('"$command" needs exactly one <url>. $cliUsage');
  }
  if (!needsUrl && positionals.isNotEmpty) {
    throw CliUsageError('"$command" takes no arguments. $cliUsage');
  }

  return CliRequest(
    command: command,
    url: needsUrl ? positionals.single : null,
    quiet: flags.contains('quiet'),
    headless: flags.contains('headless'),
    loginSession: flags.contains('login-session'),
    captions: flags.contains('captions'),
    outDir: values['out'],
    type: _enumValue('type', values['type'], {'video': DownloadType.video, 'audio': DownloadType.audio}) ??
        DownloadType.video,
    quality: _enumValue('quality', values['quality'], {for (final q in VideoQuality.values) qualityName(q): q}) ??
        VideoQuality.best,
    container: _enumValue('container', values['container'], {for (final f in VideoFormat.values) f.value: f}) ??
        VideoFormat.mp4,
    audioFormat: _enumValue('audio-format', values['audio-format'], {for (final f in AudioFormat.values) f.value: f}) ??
        AudioFormat.mp3,
    audioQuality:
        _enumValue('audio-quality', values['audio-quality'], {for (final q in AudioQuality.values) audioQualityName(q): q}) ??
            AudioQuality.best,
    subtitles: _enumValue('subtitles', values['subtitles'], {
      for (final s in SubtitleOption.values)
        if (s != SubtitleOption.none) s.value: s,
    }),
    formatId: values['format-id'],
    ffmpeg: values['ffmpeg'],
    given: {...flags, ...values.keys},
  );
}

String? _flagName(String arg) => arg.startsWith('--') && !arg.contains('=') ? arg.substring(2) : null;

/// `best` for [VideoQuality.best] (whose own `value` is the internal
/// `bestvideo`), the height otherwise. The `--quality` spelling.
String qualityName(VideoQuality q) => q == VideoQuality.best ? 'best' : q.value;

/// `best` for [AudioQuality.best] (internal value `0`), else the kbps.
String audioQualityName(AudioQuality q) => q == AudioQuality.best ? 'best' : q.value;

T? _enumValue<T>(String option, String? raw, Map<String, T> choices) {
  if (raw == null) return null;
  final match = choices[raw.toLowerCase()];
  if (match != null) return match;
  throw CliUsageError(
    'Invalid value "$raw" for --$option. Choose one of: ${choices.keys.join(', ')}.',
    code: 'INVALID_VALUE',
  );
}
