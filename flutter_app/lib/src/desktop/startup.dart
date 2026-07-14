import 'startup_stub.dart'
    if (dart.library.io) 'startup_io.dart'
    as implementation;

Future<bool> startupEnabled() => implementation.startupEnabled();
Future<bool> setStartupEnabled(bool enabled) =>
    implementation.setStartupEnabled(enabled);
