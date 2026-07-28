'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const webUi = require('../../lib/web_ui');

function write(file, contents = '') {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

test('isWebUiReady requires index and a Flutter bootstrap asset', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-webui-'));
  try {
    assert.equal(webUi.isWebUiReady(root), false);
    write(path.join(root, 'flutter_app', 'build', 'web', 'index.html'), '<html></html>');
    assert.equal(webUi.isWebUiReady(root), false);
    write(path.join(root, 'flutter_app', 'build', 'web', 'main.dart.js'), '// js');
    assert.equal(webUi.isWebUiReady(root), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('ensureWebUi reports a clear error when assets and Flutter are unavailable', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-webui-missing-'));
  const previousFlutterRoot = process.env.FLUTTER_ROOT;
  const previousPath = process.env.PATH;
  try {
    delete process.env.FLUTTER_ROOT;
    process.env.PATH = '';
    assert.throws(
      () => webUi.ensureWebUi({ packageRoot: root, build: true }),
      /prebuilt web client|npm run build:web/,
    );
  } finally {
    if (previousFlutterRoot === undefined) delete process.env.FLUTTER_ROOT;
    else process.env.FLUTTER_ROOT = previousFlutterRoot;
    process.env.PATH = previousPath;
    fs.rmSync(root, { recursive: true, force: true });
  }
});
