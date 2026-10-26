/// A [StringSink] that survives its reader going away. The first write
/// that throws (stdout piped into `head -c0`, a closed agent pipe, ...)
/// marks it [closed]; every later write is dropped instead of throwing.
/// The CLI then exits with `CliExit.outputClosed` rather than crashing
/// with an unhandled exception.
class CliOutputSink implements StringSink {
  final StringSink _inner;
  bool _closed = false;

  CliOutputSink(this._inner);

  /// True once a write failed (or [markClosed] was called).
  bool get closed => _closed;

  void markClosed() => _closed = true;

  void _guard(void Function(StringSink sink) write) {
    if (_closed) return;
    try {
      write(_inner);
    } catch (_) {
      _closed = true;
    }
  }

  @override
  void write(Object? object) => _guard((s) => s.write(object));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _guard((s) => s.writeAll(objects, separator));

  @override
  void writeCharCode(int charCode) => _guard((s) => s.writeCharCode(charCode));

  @override
  void writeln([Object? object = '']) => _guard((s) => s.writeln(object));
}
