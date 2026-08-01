import 'open_url_stub.dart'
    if (dart.library.html) 'open_url_web.dart'
    if (dart.library.io) 'open_url_io.dart' as impl;

/// Opens [url] in the system browser / a new tab.
Future<void> openExternalUrl(String url) => impl.openExternalUrl(url);
