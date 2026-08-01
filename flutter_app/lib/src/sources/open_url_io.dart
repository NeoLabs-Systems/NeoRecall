import 'dart:io';

Future<void> openExternalUrl(String url) async {
  if (Platform.isMacOS) {
    final result = await Process.run('open', <String>[url]);
    if (result.exitCode != 0) {
      throw StateError('Could not open browser: ${result.stderr}');
    }
    return;
  }
  if (Platform.isWindows) {
    final result = await Process.run('cmd', <String>['/c', 'start', '', url]);
    if (result.exitCode != 0) {
      throw StateError('Could not open browser: ${result.stderr}');
    }
    return;
  }
  if (Platform.isLinux) {
    final result = await Process.run('xdg-open', <String>[url]);
    if (result.exitCode != 0) {
      throw StateError('Could not open browser: ${result.stderr}');
    }
    return;
  }
  throw UnsupportedError('Opening external URLs is not supported on this platform.');
}
