import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/install/local_backend_installer.dart';

/// A checkout that looks like a NeoRecall clone, without touching the network.
Directory _repository({required bool dirty, required bool published}) {
  final dir = Directory.systemTemp.createTempSync('neorecall-guard-');
  void git(List<String> args) {
    final result = Process.runSync('git', <String>['-C', dir.path, ...args]);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  git(<String>['init', '-q', '-b', 'main']);
  git(<String>['config', 'user.email', 'test@example.com']);
  git(<String>['config', 'user.name', 'Test']);
  git(<String>[
    'remote',
    'add',
    'origin',
    'https://github.com/NeoLabs-Systems/NeoRecall.git',
  ]);
  File('${dir.path}/README.md').writeAsStringSync('checkout\n');
  git(<String>['add', '-A']);
  git(<String>['commit', '-qm', 'base']);
  if (published) {
    // Stand in for a commit that exists on the remote, so only the dirty tree
    // is under test.
    git(<String>['update-ref', 'refs/remotes/origin/main', 'HEAD']);
  }
  if (dirty) {
    File('${dir.path}/README.md').writeAsStringSync('local work in progress\n');
  }
  return dir;
}

void main() {
  test(
    'an install refuses a checkout with uncommitted changes',
    () async {
      final repository = _repository(dirty: true, published: true);
      addTearDown(() => repository.deleteSync(recursive: true));
      final installer = LocalBackendInstaller();
      addTearDown(installer.dispose);

      await expectLater(
        installer.install(
          channel: LocalBackendChannel.stable,
          installDirectory: repository.path,
        ),
        throwsA(
          isA<LocalBackendInstallerException>()
              .having((e) => e.code, 'code', 'SETUP_CHECKOUT_DIRTY')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      // The work is still there: the guard runs before anything destructive.
      expect(
        File('${repository.path}/README.md').readAsStringSync(),
        'local work in progress\n',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an install refuses a checkout holding unpushed commits',
    () async {
      final repository = _repository(dirty: false, published: false);
      addTearDown(() => repository.deleteSync(recursive: true));
      final installer = LocalBackendInstaller();
      addTearDown(installer.dispose);

      await expectLater(
        installer.install(
          channel: LocalBackendChannel.stable,
          installDirectory: repository.path,
        ),
        throwsA(
          isA<LocalBackendInstallerException>().having(
            (e) => e.code,
            'code',
            'SETUP_CHECKOUT_UNPUSHED',
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
