/// The MIME types context uploads use, in one place, so the file picker and
/// the drag-and-drop surface never label the same file differently.
const Map<String, String> _contextTypesByExtension = <String, String>{
  'pdf': 'application/pdf',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'heic': 'image/heic',
};

const String _fallbackContextType = 'application/octet-stream';

/// The extension of [name] in lower case, or an empty string when it has none.
String contextFileExtension(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// The content type to send for a file the owner added as context.
///
/// A type the platform itself reported wins: the browser reads the file's own
/// signature for the types it knows, which beats trusting an extension. The
/// table only fills in what the platform left blank or could not name.
String contextContentTypeFor(String name, {String? declared}) {
  final String reported = (declared ?? '').trim().toLowerCase();
  if (reported.isNotEmpty && reported != _fallbackContextType) return reported;
  return _contextTypesByExtension[contextFileExtension(name)] ??
      _fallbackContextType;
}

/// The content type for a file the owner added through an image-only picker,
/// which returns images even where the platform reports no type at all.
String contextImageContentTypeFor(String name, {String? declared}) {
  final String resolved = contextContentTypeFor(name, declared: declared);
  if (resolved.startsWith('image/')) return resolved;
  return 'image/jpeg';
}
