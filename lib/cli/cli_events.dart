import 'dart:convert';

import '../core/utils/url_parser.dart';

/// Writes the CLI's JSON lines (one object per line, `event` first).
/// stdout carries nothing else: no banners, no human text mode.
///
/// This is the single emission boundary, so it is also where output is
/// made safe: every string anywhere in an event (titles, authors, format
/// ids, caption codes, messages, paths) passes through [redact] before it
/// is encoded, and every non-finite double (NaN/Infinity, which
/// `jsonEncode` cannot represent) becomes null. Callers cannot forget
/// either step for a new field.
/// Shared by every emitter of one CLI run (the command's own and the zone
/// guard's): once a terminal event (`result` or `error`) has been written,
/// nothing else is, and the command checks [terminated] before it saves
/// anything or reports success.
class CliRunState {
  bool _terminated = false;

  bool get terminated => _terminated;

  void terminate() => _terminated = true;

  /// Set by `download` once the output file is confirmed on disk.
  bool savedFile = false;
}

/// Thrown into the download pipeline (from its progress callback) when the
/// run already ended with an error, so a detached failure stops the
/// download instead of letting it finish behind the reported error.
class CliAborted implements Exception {
  const CliAborted();

  @override
  String toString() => 'The command was stopped after an earlier error.';
}

class CliEmitter {
  final StringSink _out;
  final bool _quiet;
  final String Function(String) _redact;
  final CliRunState state;
  double _lastProgress = -1;

  CliEmitter(this._out, {bool quiet = false, String Function(String)? redact, CliRunState? state})
      : _quiet = quiet,
        _redact = redact ?? UrlParser.redactUrlsInText,
        state = state ?? CliRunState();

  /// True once this run wrote its terminal event.
  bool get terminated => state.terminated;

  /// Set once a write to the sink threw: later events are dropped (the
  /// reader is gone). Exit 8 is decided from `CliOutputSink.closed`.
  bool _broken = false;

  void _emit(Map<String, Object?> event) {
    if (_broken || state.terminated) return;
    final line = jsonEncode(_sanitize(event));
    try {
      _out.writeln(line);
    } catch (_) {
      _broken = true;
    }
  }

  Object? _sanitize(Object? value) {
    if (value is String) return _redact(value);
    if (value is double) return value.isFinite ? value : null;
    if (value is Map) return {for (final e in value.entries) e.key.toString(): _sanitize(e.value)};
    if (value is Iterable) return [for (final v in value) _sanitize(v)];
    return value;
  }

  void status(String message) => _emit({'event': 'status', 'message': message});

  /// Progress is throttled to 1% steps (plus every 0.0 / 1.0 edge): the
  /// pipeline reports far more often than an agent needs to read. It is
  /// per stage, not monotonic over the whole job: a retry with another
  /// format, or the merge/convert step, can start again near 0.
  void progress(double fraction) {
    if (_quiet) return;
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0).toDouble();
    final edge = clamped == 0.0 || clamped == 1.0;
    if (!edge && (clamped - _lastProgress).abs() < 0.01) return;
    if (clamped == _lastProgress) return;
    _lastProgress = clamped;
    _emit({'event': 'progress', 'fraction': double.parse(clamped.toStringAsFixed(4))});
  }

  /// Terminal: after it, this run emits nothing more.
  void result(String kind, Map<String, Object?> fields) {
    _emit({'event': 'result', 'kind': kind, ...fields});
    state.terminate();
  }

  /// Terminal: after it, this run emits nothing more.
  void error(String code, String message) {
    _emit({'event': 'error', 'code': code, 'message': message});
    state.terminate();
  }
}
