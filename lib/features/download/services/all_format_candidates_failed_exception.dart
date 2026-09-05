/// Thrown by [MediaDownloadPipeline.download] when every ranked format
/// candidate it tried (download, merge/convert, or the post-download
/// sanity check) failed. `toString()` is a self-contained what/why/next
/// message (what: could not download; why: N candidates tried, last
/// error; next: try again or a different quality/format), which is why
/// `DownloadService._describeDownloadError`'s catch-all
/// `return e.toString();` renders it correctly without needing its own
/// branch there.
class AllFormatCandidatesFailedException implements Exception {
  final int attempted;
  final Object lastError;

  const AllFormatCandidatesFailedException(this.attempted, this.lastError);

  @override
  String toString() {
    return 'Could not download this video: tried $attempted format(s) and all failed '
        '(last error: $lastError). Check the URL and try again, or try a different quality/format setting.';
  }
}
