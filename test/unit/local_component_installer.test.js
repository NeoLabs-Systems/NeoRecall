'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ComponentInstaller } = require('../../server/local_runtime/component_installer');
const { fileServer } = require('../helpers/file_server');
const { makeTarGz, makeZip, sha256 } = require('../helpers/archives');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-installer-'));
test.after(() => fs.rmSync(root, { recursive: true, force: true }));

const config = { localDownloadAttempts: 2, localDownloadIdleTimeoutMs: 500, localInstallRetryMs: 60_000 };
const tool = Buffer.from('#!/bin/sh\necho tool\n');
const tarball = makeTarGz('srv-1', { 'bin/tool': tool, 'lib/helper.so': Buffer.from('helper') });
const library = Buffer.from('shared library '.repeat(300));
const wheel = makeZip({ 'pkg/lib.so': library, 'pkg/other.py': Buffer.from('x') });
const weights = Buffer.alloc(120_000, 7);

let directoryCounter = 0;
const freshDirectory = () => path.join(root, `component-${directoryCounter += 1}`);

async function fixture({ weightsBody = weights } = {}) {
  const server = await fileServer({ '/srv.tar.gz': { body: tarball }, '/pkg.whl': { body: wheel }, '/weights.bin': { body: weightsBody } });
  const manifest = {
    components: [{
      id: 'demo', kind: 'speech', label: 'Demo', license: 'Apache-2.0', languages: ['en'],
      files: [{ id: 'weights', type: 'file', path: 'weights/w.bin', url: server.url('/weights.bin'), size: weightsBody.length, sha256: sha256(weightsBody) }],
      platforms: {
        'test-1': {
          artifacts: [
            { id: 'server', type: 'tar-archive', filename: 'srv.tar.gz', url: server.url('/srv.tar.gz'), size: tarball.length, sha256: sha256(tarball), stripComponents: 1, extractTo: 'srv', check: 'srv/bin/tool' },
            { id: 'engine', type: 'zip-member', filename: 'pkg.whl', url: server.url('/pkg.whl'), size: wheel.length, sha256: sha256(wheel), member: 'pkg/lib.so', path: 'engine/lib.so', fileSize: library.length, fileSha256: sha256(library) },
          ],
        },
      },
    }],
  };
  return { server, manifest };
}

const installerFor = (manifest, directory, smoke = async () => {}, platform = 'test-1') =>
  new ComponentInstaller({ manifest, componentId: 'demo', directory, platform, config, smoke });

test('installs every artifact, proves the stack, and only then says installed', async () => {
  const { server, manifest } = await fixture();
  const directory = freshDirectory();
  const order = [];
  const installer = installerFor(manifest, directory, async (component) => {
    order.push('smoke');
    assert.equal(component.status().phase, 'installing', 'not installed until the smoke test passes');
    assert.ok(fs.existsSync(component.pathOf('server')) && fs.existsSync(component.pathOf('engine')) && fs.existsSync(component.pathOf('weights')));
  });
  assert.equal(installer.status().phase, 'not_installed');
  const status = await installer.ensureInstalled();
  assert.deepEqual(order, ['smoke']);
  assert.equal(status.phase, 'installed');
  assert.deepEqual(fs.readFileSync(installer.pathOf('engine')), library);
  assert.deepEqual(fs.readFileSync(installer.pathOf('server')), tool);
  assert.ok(fs.statSync(installer.pathOf('server')).mode & 0o100, 'extracted programs stay executable');
  assert.equal(fs.existsSync(path.join(directory, '.downloads')), false, 'archives are removed once installed');
  assert.equal(installer.isInstalled(), true);
  await server.close();
});

test('an installed component costs no network on the next call or the next process', async () => {
  const { server, manifest } = await fixture();
  const directory = freshDirectory();
  await installerFor(manifest, directory).ensureInstalled();
  const hits = server.hits.length;
  const again = installerFor(manifest, directory);
  assert.equal(again.isInstalled(), true, 'a new process recognises the install from disk');
  await again.ensureInstalled();
  assert.equal(server.hits.length, hits);
  await server.close();
});

test('a failing smoke test is recorded, not retried at once, and retried on demand', async () => {
  const { server, manifest } = await fixture();
  const directory = freshDirectory();
  let attempts = 0;
  const installer = installerFor(manifest, directory, async () => {
    attempts += 1;
    if (attempts === 1) throw Object.assign(new Error('the worker would not load'), { code: 'LOCAL_ASR_LOAD_FAILED' });
  });
  const failed = await installer.ensureInstalled();
  assert.equal(failed.phase, 'failed');
  assert.equal(failed.error.code, 'LOCAL_ASR_LOAD_FAILED');
  assert.equal(installer.isInstalled(), false);
  const hits = server.hits.length;
  assert.equal((await installer.ensureInstalled()).phase, 'failed', 'inside the retry interval nothing is attempted');
  assert.equal(attempts, 1);
  const recovered = await installer.ensureInstalled({ force: true });
  assert.equal(recovered.phase, 'installed');
  assert.equal(server.hits.length, hits, 'the verified downloads were kept, so the retry only re-ran the check');
  await server.close();
});

test('moving a pin in the manifest re-fetches only what changed', async () => {
  const first = await fixture();
  const directory = freshDirectory();
  await installerFor(first.manifest, directory).ensureInstalled();
  await first.server.close();
  const newer = Buffer.alloc(90_000, 9);
  const second = await fixture({ weightsBody: newer });
  const installer = installerFor(second.manifest, directory);
  assert.equal(installer.isInstalled(), false, 'an install made under the old pins is not current');
  await installer.ensureInstalled();
  assert.equal(installer.isInstalled(), true);
  assert.deepEqual(fs.readFileSync(installer.pathOf('weights')), newer);
  assert.deepEqual(second.server.hits.map((hit) => hit.url), ['/weights.bin'], 'the program and library were already correct');
  await second.server.close();
});

test('two installers on one directory install once between them', async () => {
  const { server, manifest } = await fixture();
  const directory = freshDirectory();
  const a = installerFor(manifest, directory, () => new Promise((resolve) => setTimeout(resolve, 150)));
  const b = installerFor(manifest, directory);
  const running = a.ensureInstalled();
  assert.equal(b.status().phase, 'installing', 'the second process sees the first one working');
  assert.equal((await b.ensureInstalled()).phase, 'installing', 'and does not start a competing install');
  assert.equal((await running).phase, 'installed');
  assert.equal(server.hits.filter((hit) => hit.url === '/weights.bin').length, 1);
  await server.close();
});

test('a lock left by a dead process is taken over', async () => {
  const { server, manifest } = await fixture();
  const directory = freshDirectory();
  fs.mkdirSync(directory, { recursive: true });
  const lock = path.join(directory, 'install.lock');
  fs.writeFileSync(lock, '');
  const old = new Date(Date.now() - 10 * 60_000);
  fs.utimesSync(lock, old, old);
  const installer = installerFor(manifest, directory);
  assert.equal(installer.status().phase, 'not_installed');
  assert.equal((await installer.ensureInstalled()).phase, 'installed');
  await server.close();
});

test('a platform with no published runtime is reported, never attempted', async () => {
  const { server, manifest } = await fixture();
  const installer = installerFor(manifest, freshDirectory(), async () => {}, 'plan9-mips');
  assert.equal(installer.supported, false);
  const status = await installer.ensureInstalled();
  assert.equal(status.phase, 'unsupported');
  assert.match(status.reason, /plan9-mips/);
  assert.equal(server.hits.length, 0);
  await server.close();
});
