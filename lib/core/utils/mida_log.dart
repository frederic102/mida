import 'dart:io';

import 'url_parser.dart';

/// Pure-Dart debug logger for code that must run both inside the Flutter app
/// and under plain `dart run` (the agent CLI, `lib/cli/`). Writes to stderr
/// only when the `MIDA_DEBUG=1` environment variable is set, otherwise it is
/// a no-op. Deliberately not `debugPrint`: that lives in `package:flutter`,
/// and importing it would drag Flutter into the CLI compile. Query strings
/// are stripped ([UrlParser.redactUrlsInText]): signed media URLs carry
/// their credentials there, and stderr ends up in agent transcripts.
void midaLog(String message) {
  if (Platform.environment['MIDA_DEBUG'] != '1') return;
  stderr.writeln(UrlParser.redactUrlsInText(message));
}
