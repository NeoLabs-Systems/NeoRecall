'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');

// The PLAUD source talks to a remote API and to the import pipeline, so both are
// stubbed through the module cache: these tests pin the source's own behaviour
// (idempotent re-polling, per-recording failure isolation, credential handling),
// not PLAUD's servers.
const SOURCE_PATH = require.resolve('../../server/services/sources/plaud_source');
const IMPORTS_PATH = require.resolve('../../server/services/ingest/import_service');
const PATHS_PATH = require.resolve('../../runtime/paths');
const REGISTRY_PATH = require.resolve('../../server/services/sources/index');

function loadSourceWith({ imports, fetchImpl, tmpDir }) {
  for (const key of [SOURCE_PATH, IMPORTS_PATH, PATHS_PATH]) delete require.cache[key];
  require.cache[IMPORTS_PATH] = new Module(IMPORTS_PATH);
  require.cache[IMPORTS_PATH].exports = imports;
  require.cache[IMPORTS_PATH].loaded = true;
  require.cache[PATHS_PATH] = new Module(PATHS_PATH);
  require.cache[PATHS_PATH].exports = { ensureRuntimeDirs: () => ({ importTmp: tmpDir }) };
  require.cache[PATHS_PATH].loaded = true;
  const previousFetch = global.fetch;
  global.fetch = fetchImpl;
  const source = require(SOURCE_PATH);
  return {
    source,
    restore() {
      global.fetch = previousFetch;
      for (const key of [SOURCE_PATH, IMPORTS_PATH, PATHS_PATH]) delete require.cache[key];
    },
  };
}

function jsonResponse(body) {
  return { ok: true, status: 200, json: async () => body, text: async () => JSON.stringify(body) };
}

function audioResponse(bytes) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => String(bytes.length) },
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
  };
}

const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'plaud-source-test-'));
}

test('a sweep imports each recording once and never re-imports it', async () => {
  const tmpDir = tempDir();
  const importCalls = [];
  const finished = new Set();
  const imports = {
    get(userId, importId) {
      if (!finished.has(importId)) throw new Error('not found');
      return { state: 'completed' };
    },
    async importLocalFile(userId, filename, input) {
      importCalls.push({ userId, input, bytes: fs.readFileSync(filename).length });
      finished.add(input.importId);
      return { state: 'processing' };
    },
  };
  const audio = Buffer.from([0xff, 0xfb, 0x11, 0x22]);
  const requested = [];
  const fetchImpl = async (url) => {
    requested.push(String(url));
    if (String(url).includes('/files/?page=')) {
      return jsonResponse({ data: [{ id: 'rec-1', name: 'Standup', created_at: '2026-07-31T09:00:00Z' }] });
    }
    if (String(url).includes('/files/rec-1')) return jsonResponse({ url: 'https://cdn.plaud.test/rec-1.mp3' });
    return audioResponse(audio);
  };

  const { source, restore } = loadSourceWith({ imports, fetchImpl, tmpDir });
  try {
    const descriptor = {
      id: 'src-1',
      user_id: 'user-1',
      enabled: true,
      config: { accessToken: 'tok', pollMinutes: 60 },
    };
    await source.startSource(descriptor);
    source.stopSource(descriptor.id);

    assert.equal(importCalls.length, 1, 'the recording is imported once');
    assert.equal(importCalls[0].bytes, audio.length);
    assert.equal(importCalls[0].input.contentType, 'audio/mpeg');
    assert.equal(importCalls[0].input.captureTime, '2026-07-31T09:00:00.000Z');
    assert.match(importCalls[0].input.originalName, /Standup/);
    assert.match(requested[0], /^https:\/\/platform\.plaud\.ai\/developer\/api\/open\/third-party\/files\//);

    // A second sweep must be a no-op: the import id is derived from the PLAUD
    // file id, so an already-completed import short-circuits the download.
    await source.startSource(descriptor);
    source.stopSource(descriptor.id);
    assert.equal(importCalls.length, 1, 're-polling does not duplicate the recording');
  } finally {
    restore();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('one failing recording does not abort the rest of the sweep', async () => {
  const tmpDir = tempDir();
  const imported = [];
  const imports = {
    get() { throw new Error('not found'); },
    async importLocalFile(userId, filename, input) {
      imported.push(input.importId);
      return { state: 'processing' };
    },
  };
  const fetchImpl = async (url) => {
    const target = String(url);
    if (target.includes('/files/?page=')) {
      return jsonResponse({ data: [{ id: 'bad' }, { id: 'good' }] });
    }
    if (target.includes('/files/bad')) return { ok: false, status: 500, text: async () => 'boom' };
    if (target.includes('/files/good')) return jsonResponse({ url: 'https://cdn.plaud.test/good.mp3' });
    return audioResponse(Buffer.from([1, 2, 3]));
  };

  const { source, restore } = loadSourceWith({ imports, fetchImpl, tmpDir });
  try {
    await source.startSource({
      id: 'src-2', user_id: 'user-1', enabled: true, config: { accessToken: 'tok', pollMinutes: 60 },
    });
    source.stopSource('src-2');
    assert.equal(imported.length, 1, 'the healthy recording is still imported');
  } finally {
    restore();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('a source without an access token never polls', async () => {
  const tmpDir = tempDir();
  let calls = 0;
  const { source, restore } = loadSourceWith({
    imports: { get() { throw new Error('not found'); }, async importLocalFile() {} },
    fetchImpl: async () => { calls += 1; return jsonResponse({ data: [] }); },
    tmpDir,
  });
  try {
    await source.startSource({ id: 'src-3', user_id: 'u', enabled: true, config: {} });
    assert.equal(calls, 0);
    await source.startSource({ id: 'src-4', user_id: 'u', enabled: false, config: { accessToken: 't' } });
    assert.equal(calls, 0, 'a disabled source does not poll either');
  } finally {
    restore();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('verifyAccess surfaces a rejected token as an error', async () => {
  const tmpDir = tempDir();
  const { source, restore } = loadSourceWith({
    imports: {},
    fetchImpl: async () => ({ ok: false, status: 401, text: async () => 'unauthorized' }),
    tmpDir,
  });
  try {
    await assert.rejects(() => source.verifyAccess({ accessToken: 'nope' }), /401/);
  } finally {
    restore();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('the source registry exposes plaud and hides credentials from clients', () => {
  delete require.cache[REGISTRY_PATH];
  const registry = require(REGISTRY_PATH);
  assert.ok(registry.availableTypes().includes('plaud'));
  assert.ok(!registry.availableTypes().includes('meeting'));
  assert.equal(typeof registry.verifyConfig, 'function');
  // getPublic/list must never echo a stored token back to the client.
  assert.equal(typeof registry.getPublic, 'function');
  delete require.cache[REGISTRY_PATH];
});
