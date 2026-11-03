'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { buildBundledWebClientIfPossible } = require('../../lib/install_helpers');

function buildWith(version) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nrecall-install-'));
  const flutterAppDir = path.join(root, 'flutter_app');
  fs.mkdirSync(flutterAppDir);
  fs.writeFileSync(path.join(flutterAppDir, 'pubspec.yaml'), 'name: x\n');
  const commands = [];
  const upgrades = [];
  buildBundledWebClientIfPossible({
    flutterAppDir,
    webClientDir: path.join(flutterAppDir, 'build', 'web'),
    runCommand: (_command, args) => {
      commands.push(args.join(' '));
      if (args[0] === '--version') return { status: 0, stdout: `Welcome\n{"frameworkVersion":"${version}"}` };
      return { status: 0 };
    },
    commandExistsFn: () => true,
    onFlutterUpgradeStart: (target) => upgrades.push(target),
    fail: (message) => assert.fail(message),
  });
  return { commands, upgrades };
}

test('an older Flutter is upgraded before the build', () => {
  const { commands, upgrades } = buildWith('3.35.5');
  assert.equal(upgrades.length, 1);
  assert.ok(commands.indexOf('upgrade') < commands.indexOf('pub get'));
});

test('a new enough Flutter is left alone', () => {
  assert.ok(!buildWith('3.47.9').commands.includes('upgrade'));
});

test('a Flutter that reports no version is left alone', () => {
  assert.ok(!buildWith('0.0.0-unknown').commands.includes('upgrade'));
});
