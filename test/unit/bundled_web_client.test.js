'use strict';

// The built web client is committed because the Git installer clones this
// repository and serves it directly on machines with no Flutter SDK — so this
// artifact, not CI's, is what those users get.
//
// It is served under /app, and a build made without `--base-href /app/` asks
// for flutter_bootstrap.js at the site root instead. Every request 404s and the
// page stays blank, with nothing in the server log to say why. That had
// happened: the committed index.html carried `<base href="/">`.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const webRoot = path.join(__dirname, '..', '..', 'flutter_app', 'build', 'web');

test('the bundled web client is built for the path it is served from', () => {
  const indexPath = path.join(webRoot, 'index.html');
  assert.ok(fs.existsSync(indexPath), 'flutter_app/build/web/index.html is committed and must exist');
  const html = fs.readFileSync(indexPath, 'utf8');
  const base = html.match(/<base href="([^"]*)">/);
  assert.ok(base, 'index.html must declare a <base href>');
  assert.equal(
    base[1],
    '/app/',
    'rebuild with: flutter build web --release --base-href /app/',
  );
});

test('the bundled web client has the entry points the page asks for', () => {
  for (const file of ['flutter_bootstrap.js', 'main.dart.js']) {
    const full = path.join(webRoot, file);
    assert.ok(fs.existsSync(full), `${file} is missing from the bundled client`);
    assert.ok(fs.statSync(full).size > 0, `${file} is present but empty`);
  }
});
