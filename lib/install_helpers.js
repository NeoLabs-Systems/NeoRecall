'use strict';

const fs = require('node:fs');
const path = require('node:path');

function withInstallEnv(extraEnv = {}) {
  return {
    ...process.env,
    ...extraEnv,
  };
}

function commandExists(runCommand, cmd) {
  const result = runCommand(process.platform === 'win32' ? 'where' : 'which', [cmd]);
  return result.status === 0;
}

function hasBundledWebClient(webClientDir) {
  return fs.existsSync(path.join(webClientDir, 'index.html'))
    && (
      fs.existsSync(path.join(webClientDir, 'main.dart.js'))
      || fs.existsSync(path.join(webClientDir, 'flutter_bootstrap.js'))
      || fs.existsSync(path.join(webClientDir, 'flutter.js'))
    );
}

function buildBundledWebClientIfPossible({
  flutterAppDir,
  webClientDir,
  runCommand,
  commandExistsFn,
  onMissingSources,
  onUsingBundledClient,
  onMissingFlutter,
  onBuildStart,
  onBuildSuccess,
  onBuildFailed,
  fail,
  required = false,
}) {
  if (!fs.existsSync(path.join(flutterAppDir, 'pubspec.yaml'))) {
    if (hasBundledWebClient(webClientDir)) {
      onUsingBundledClient?.();
      return false;
    }
    if (required) fail(`Missing Flutter app sources at ${flutterAppDir}`);
    onMissingSources?.();
    return false;
  }

  if (!commandExistsFn('flutter')) {
    if (hasBundledWebClient(webClientDir)) {
      onMissingFlutter?.();
      return false;
    }
    fail('Flutter SDK is required to build the web client because no bundled client was found.');
  }

  const pubGet = runCommand('flutter', ['pub', 'get'], {
    cwd: flutterAppDir,
    env: withInstallEnv(),
  });
  if (pubGet.status !== 0) fail('Flutter pub get failed before web rebuild.');

  onBuildStart?.();
  const build = runCommand(
    'flutter',
    ['build', 'web', '--release', '--base-href', '/app/'],
    {
      cwd: flutterAppDir,
      env: withInstallEnv(),
    },
  );
  if (build.status !== 0) {
    if (hasBundledWebClient(webClientDir)) {
      onBuildFailed?.();
      return false;
    }
    fail('Flutter web build failed and no bundled web client is available.');
  }
  onBuildSuccess?.();
  return true;
}

module.exports = {
  withInstallEnv,
  commandExists,
  hasBundledWebClient,
  buildBundledWebClientIfPossible,
};
