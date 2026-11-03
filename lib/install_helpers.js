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

// The web client only works on iOS 26 Safari from this Flutter on. Older ones
// still build it, so a failed upgrade doesn't stop the build.
const REQUIRED_FLUTTER_VERSION = '3.47.9';

function isOlderVersion(version, minimum) {
  const parts = (value) => value.split('-')[0].split('.').map(Number);
  const [left, right] = [parts(version), parts(minimum)];
  for (let index = 0; index < right.length; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index];
  }
  return false;
}

function upgradeOlderFlutter({ flutter, runCommand, onFlutterUpgradeStart }) {
  const result = runCommand(flutter, ['--version', '--machine'], { env: withInstallEnv() });
  // First runs can print banners before the JSON.
  const start = String(result.stdout || '').indexOf('{');
  if (result.status !== 0 || start < 0) return;
  let version = '';
  try {
    version = JSON.parse(result.stdout.slice(start)).frameworkVersion || '';
  } catch {
    return;
  }
  if (!/^[1-9]\d*\.\d+\.\d+/.test(version) || !isOlderVersion(version, REQUIRED_FLUTTER_VERSION)) return;
  onFlutterUpgradeStart?.(REQUIRED_FLUTTER_VERSION);
  runCommand(flutter, ['upgrade'], { env: withInstallEnv() });
}

function buildBundledWebClientIfPossible({
  flutterAppDir,
  webClientDir,
  runCommand,
  commandExistsFn,
  onMissingSources,
  onUsingBundledClient,
  onMissingFlutter,
  onFlutterUpgradeStart,
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

  upgradeOlderFlutter({ flutter: 'flutter', runCommand, onFlutterUpgradeStart });

  const clean = runCommand('flutter', ['clean'], {
    cwd: flutterAppDir,
    env: withInstallEnv(),
  });
  if (clean.status !== 0) fail('Flutter clean failed before web rebuild.');

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
