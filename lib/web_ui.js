'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function packageRoot(explicitRoot) {
  return explicitRoot || path.join(__dirname, '..');
}

function webUiRoot(explicitRoot) {
  return path.join(packageRoot(explicitRoot), 'flutter_app', 'build', 'web');
}

function flutterProjectRoot(explicitRoot) {
  return path.join(packageRoot(explicitRoot), 'flutter_app');
}

function isWebUiReady(explicitRoot) {
  const root = webUiRoot(explicitRoot);
  return fs.existsSync(path.join(root, 'index.html'))
    && (
      fs.existsSync(path.join(root, 'main.dart.js'))
      || fs.existsSync(path.join(root, 'flutter_bootstrap.js'))
      || fs.existsSync(path.join(root, 'flutter.js'))
    );
}

function resolveFlutterBinary() {
  if (process.env.FLUTTER_ROOT) {
    const candidate = path.join(
      process.env.FLUTTER_ROOT,
      'bin',
      process.platform === 'win32' ? 'flutter.bat' : 'flutter',
    );
    if (fs.existsSync(candidate)) return candidate;
  }
  const lookup = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['flutter'], {
    encoding: 'utf8',
    env: process.env,
  });
  if (lookup.status !== 0) return null;
  const resolved = String(lookup.stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean);
  return resolved || null;
}

function canBuildWebUi(explicitRoot) {
  return fs.existsSync(path.join(flutterProjectRoot(explicitRoot), 'pubspec.yaml'))
    && Boolean(resolveFlutterBinary());
}

function buildWebUi(explicitRoot) {
  const flutter = resolveFlutterBinary();
  if (!flutter) throw new Error('Flutter is not installed, so the NeoRecall web UI cannot be built on this machine.');
  const project = flutterProjectRoot(explicitRoot);
  if (!fs.existsSync(path.join(project, 'pubspec.yaml'))) {
    throw new Error('Flutter project sources are not available in this installation.');
  }
  process.stdout.write('Building NeoRecall web UI...\n');
  const result = spawnSync(flutter, ['build', 'web', '--release', '--base-href', '/app/'], {
    cwd: project,
    env: process.env,
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Flutter web build failed with exit code ${result.status}.`);
}

function missingWebUiMessage(explicitRoot) {
  const root = webUiRoot(explicitRoot);
  if (canBuildWebUi(explicitRoot)) {
    return `NeoRecall web UI assets are missing at ${root}. Install Flutter dependencies if needed, then re-run setup so the client can be built automatically.`;
  }
  return `NeoRecall web UI assets are missing at ${root}. Reinstall a published NeoRecall package that includes the prebuilt web client, or install Flutter and run \`npm run build:web\` from a source checkout.`;
}

function ensureWebUi({ packageRoot: explicitRoot, build = true } = {}) {
  if (isWebUiReady(explicitRoot)) {
    return { path: webUiRoot(explicitRoot), built: false };
  }
  if (build && canBuildWebUi(explicitRoot)) {
    buildWebUi(explicitRoot);
    if (isWebUiReady(explicitRoot)) {
      return { path: webUiRoot(explicitRoot), built: true };
    }
  }
  throw new Error(missingWebUiMessage(explicitRoot));
}

module.exports = {
  packageRoot,
  webUiRoot,
  flutterProjectRoot,
  isWebUiReady,
  canBuildWebUi,
  buildWebUi,
  ensureWebUi,
  missingWebUiMessage,
  resolveFlutterBinary,
};
