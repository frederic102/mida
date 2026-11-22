/// Text from a web page (a video title, a channel name) made safe to show:
/// one line, with control characters and invisible format characters
/// (zero width spaces, bidirectional overrides such as U+202E, a BOM) removed
/// so a title cannot reorder or hide the text around it.
String displayText(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[\p{Cc}\p{Cf}]', unicode: true), '').trim();
