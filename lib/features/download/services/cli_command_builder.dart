import '../../../cli/cli_args.dart' show audioQualityName, qualityName;
import '../models/download_models.dart';

/// What the "Copy command" button offers for one queued download: the
/// command, or why there is none.
class CliCommandResult {
  final String? command;

  /// Why no command could be built (shown as the disabled button's
  /// tooltip). Null when [command] is set.
  final String? refusal;

  const CliCommandResult.ok(String this.command) : refusal = null;

  const CliCommandResult.refused(String this.refusal) : command = null;
}

/// Builds the "Copy command (PowerShell or bash)" text for a queued
/// download: the same job (type, quality, container, audio format and
/// quality, captions, browser login session, folder) as a `mida-cli` line.
///
/// Quoting model: the URL and the folder are copied byte for byte inside
/// single quotes. In PowerShell and in bash a single-quoted string is fully
/// literal (no `$`, backtick, `!` or `%` expansion), so the CLI receives
/// exactly what was queued; nothing is percent-encoded, because encoding
/// can change what a server sees (`/a$b` and `/a%24b` are different
/// request targets for a server that signs or compares them).
///
/// cmd.exe is not a target: it has no literal quoting at all. The command
/// is refused (null [CliCommandResult.command]) when the URL or the folder
/// holds a character single quotes cannot carry in both shells: a single
/// quote (ASCII, or the typographic ones PowerShell also treats as quotes),
/// a double quote (Windows PowerShell 5.1 breaks it when passing arguments
/// to a program), or any control character including newline and NUL. The
/// folder is never silently dropped: no folder, no command.
class CliCommandBuilder {
  const CliCommandBuilder();

  static const label = 'Copy command (PowerShell or bash)';

  CliCommandResult build({
    required String url,
    required DownloadType type,
    required DownloadOptions options,
    required String outDir,
    bool loginSession = false,
  }) {
    final urlProblem = unquotable(url);
    if (urlProblem != null) return CliCommandResult.refused('The link contains $urlProblem.');
    // Validate the folder exactly as set (a trailing newline must refuse, a
    // trailing space must survive), then drop trailing separators only.
    final dirProblem = unquotable(outDir);
    if (dirProblem != null) return CliCommandResult.refused('The download folder path contains $dirProblem.');
    final dir = _trimDir(outDir);
    if (dir.isEmpty) return const CliCommandResult.refused('No download folder is set.');

    final parts = <String>['mida-cli', 'download', "'$url'"];
    if (type == DownloadType.audio) {
      parts.addAll(['--type', 'audio']);
      if (options.audioFormat != AudioFormat.mp3) parts.addAll(['--audio-format', options.audioFormat.value]);
      if (options.audioQuality != AudioQuality.best) {
        parts.addAll(['--audio-quality', audioQualityName(options.audioQuality)]);
      }
    } else {
      if (options.videoQuality != VideoQuality.best) parts.addAll(['--quality', qualityName(options.videoQuality)]);
      if (options.videoFormat != VideoFormat.mp4) parts.addAll(['--container', options.videoFormat.value]);
      switch (options.subtitleOption) {
        case SubtitleOption.none:
          break;
        case SubtitleOption.koreanEnglish:
          // Same as `--subtitles ko,en`, without a comma PowerShell would
          // turn into an array.
          parts.add('--captions');
        case SubtitleOption.korean || SubtitleOption.english:
          parts.addAll(['--subtitles', options.subtitleOption.value]);
      }
    }
    if (loginSession) parts.add('--login-session');
    parts.addAll(['--out', "'$dir'"]);
    return CliCommandResult.ok(parts.join(' '));
  }

  /// A description of the first character in [text] that single quotes
  /// cannot carry literally in both PowerShell and bash, or null.
  static String? unquotable(String text) {
    for (final c in text.runes) {
      if (c == 0x27 || (c >= 0x2018 && c <= 0x201b)) return 'a single quote';
      if (c == 0x22 || (c >= 0x201c && c <= 0x201f)) return 'a double quote';
      if (c < 0x20 || c == 0x7f || (c >= 0x80 && c <= 0x9f) || c == 0x2028 || c == 0x2029) {
        return 'a control character (for example a line break)';
      }
    }
    return null;
  }

  /// Drops trailing separators (Windows PowerShell 5.1 would otherwise pass
  /// `C:\My Videos\` as `"C:\My Videos\"`, whose `\"` the program reads as
  /// a literal quote), but keeps a drive root such as `C:\`.
  static String _trimDir(String dir) {
    var d = dir;
    while (d.length > 1 && (d.endsWith(r'\') || d.endsWith('/'))) {
      final shorter = d.substring(0, d.length - 1);
      if (RegExp(r'^[A-Za-z]:$').hasMatch(shorter)) break;
      d = shorter;
    }
    return d;
  }
}
