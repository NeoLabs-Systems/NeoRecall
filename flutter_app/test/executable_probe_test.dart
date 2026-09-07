import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/install/local_backend_installer.dart';

void main() {
  late Directory tools;

  setUp(() {
    tools = Directory.systemTemp.createTempSync('neorecall-probe-');
  });

  tearDown(() {
    tools.deleteSync(recursive: true);
    // The scratch tools are deliberately absent from PATH, so nothing else
    // could have picked them up.
  });

  File write(String name, String contents) {
    final file = File('${tools.path}/$name')..writeAsStringSync(contents);
    Process.runSync('chmod', <String>['+x', file.path]);
    return file;
  }

  test('a script is usable when its interpreter sits beside it', () async {
    // npm is exactly this shape: `#!/usr/bin/env node`, installed next to the
    // node it needs, with neither on the PATH a window-server launch provides.
    write('probe-runtime', '#!/bin/sh\necho v1.2.3\n');
    final script = write('probe-tool', '#!/usr/bin/env probe-runtime\n');

    final installer = LocalBackendInstaller();
    addTearDown(installer.dispose);
    expect(await installer.probeExecutable(script.path), isTrue);
  });

  test('a stand-in that cannot run is rejected', () async {
    // /usr/bin/git on a Mac without command line tools behaves this way: the
    // file is there and only prints an error when run.
    final shim = write(
      'probe-shim',
      '#!/bin/sh\necho "not a developer tool" >&2\nexit 1\n',
    );

    final installer = LocalBackendInstaller();
    addTearDown(installer.dispose);
    expect(await installer.probeExecutable(shim.path), isFalse);
  });

  test('a missing interpreter is rejected', () async {
    final orphan = write(
      'probe-orphan',
      '#!/usr/bin/env definitely-not-installed\n',
    );

    final installer = LocalBackendInstaller();
    addTearDown(installer.dispose);
    expect(await installer.probeExecutable(orphan.path), isFalse);
  });
}
