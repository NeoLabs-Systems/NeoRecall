import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

bool _configured = false;
void _configure() {
  if (_configured || !(Platform.isMacOS || Platform.isWindows)) return;
  launchAtStartup.setup(
    appName: 'NeoRecall',
    appPath: Platform.resolvedExecutable,
    packageName: 'systems.neolabs.neorecall',
  );
  _configured = true;
}

Future<bool> startupEnabled() async {
  _configure();
  return launchAtStartup.isEnabled();
}

Future<bool> setStartupEnabled(bool enabled) async {
  _configure();
  return enabled ? launchAtStartup.enable() : launchAtStartup.disable();
}
