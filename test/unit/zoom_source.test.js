'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

const SOURCE_PATH = require.resolve('../../server/services/sources/zoom_source');
const PLATFORM_PATH = require.resolve('../../server/services/sources/platforms/zoom');
const CATALOG_PATH = require.resolve('../../server/services/sources/platforms/catalog');
const OAUTH_PATH = require.resolve('../../server/services/sources/oauth/outbound_oauth');
const BASE_PATH = require.resolve('../../server/services/sources/cloud/cloud_import_base');
const IMPORTS_PATH = require.resolve('../../server/services/ingest/import_service');
const PATHS_PATH = require.resolve('../../runtime/paths');
const CONFIG_PATH = require.resolve('../../server/config');
const REGISTRY_PATH = require.resolve('../../server/services/sources/index');

function loadZoom({ imports, fetchImpl, tmpDir, descriptor }) {
  for (const key of [SOURCE_PATH, PLATFORM_PATH, BASE_PATH, IMPORTS_PATH, PATHS_PATH, CATALOG_PATH, OAUTH_PATH, CONFIG_PATH, REGISTRY_PATH]) {
    delete require.cache[key];
  }

  require.cache[CONFIG_PATH] = new Module(CONFIG_PATH);
  require.cache[CONFIG_PATH].exports = {
    getConfig: () => ({
      zoomOauthClientId: 'zoom-client',
      zoomOauthClientSecret: 'zoom-secret',
      publicUrl: 'https://neorecall.test',
    }),
  };
  require.cache[CONFIG_PATH].loaded = true;

  require.cache[IMPORTS_PATH] = new Module(IMPORTS_PATH);
  require.cache[IMPORTS_PATH].exports = imports;
  require.cache[IMPORTS_PATH].loaded = true;

  require.cache[PATHS_PATH] = new Module(PATHS_PATH);
  require.cache[PATHS_PATH].exports = { ensureRuntimeDirs: () => ({ importTmp: tmpDir }) };
  require.cache[PATHS_PATH].loaded = true;

  require.cache[REGISTRY_PATH] = new Module(REGISTRY_PATH);
  require.cache[REGISTRY_PATH].exports = {
    get: () => descriptor,
    update: (_userId, _id, data) => {
      if (data.config) Object.assign(descriptor.config, data.config);
      if (data.enabled !== undefined) descriptor.enabled = data.enabled;
      return descriptor;
    },
  };
  require.cache[REGISTRY_PATH].loaded = true;

  const previousFetch = global.fetch;
  global.fetch = fetchImpl;
  const source = require(SOURCE_PATH);
  return {
    source,
    restore() {
      global.fetch = previousFetch;
      for (const key of [SOURCE_PATH, PLATFORM_PATH, BASE_PATH, IMPORTS_PATH, PATHS_PATH, CATALOG_PATH, OAUTH_PATH, CONFIG_PATH, REGISTRY_PATH]) {
        delete require.cache[key];
      }
    },
  };
}

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
    headers: { get: () => null },
  };
}

function audioResponse(bytes) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => String(bytes.length) },
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    text: async () => '',
    json: async () => ({}),
  };
}

test('zoom sweep imports each recording once and prefers audio files', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zoom-source-test-'));
  const importCalls = [];
  const finished = new Set();
  const imports = {
    get(_userId, importId) {
      if (!finished.has(importId)) throw new Error('not found');
      return { state: 'completed' };
    },
    async importLocalFile(userId, filename, input) {
      importCalls.push({ userId, input, bytes: fs.readFileSync(filename).length });
      finished.add(input.importId);
      return { state: 'processing' };
    },
  };
  const audio = Buffer.from([0x00, 0x01, 0x02, 0x03]);
  const requested = [];
  const fetchImpl = async (url) => {
    const href = String(url);
    requested.push(href);
    if (href.includes('/users/me/recordings')) {
      return jsonResponse({
        meetings: [
          {
            uuid: 'm1',
            topic: 'Standup',
            start_time: '2026-07-31T09:00:00Z',
            recording_files: [
              {
                id: 'f-video',
                file_type: 'MP4',
                download_url: 'https://zoom.test/download/video',
              },
              {
                id: 'f-audio',
                file_type: 'M4A',
                download_url: 'https://zoom.test/download/audio',
                recording_start: '2026-07-31T09:00:00Z',
              },
            ],
          },
        ],
      });
    }
    if (href.includes('zoom.test/download/audio')) return audioResponse(audio);
    if (href.includes('zoom.test/download/video')) {
      assert.fail('should prefer the audio file over video');
    }
    return jsonResponse({ email: 'user@example.com', id: 'u1' });
  };

  const descriptor = {
    id: 'src-zoom',
    user_id: 'user-1',
    enabled: true,
    type: 'zoom',
    config: { accessToken: 'tok', pollMinutes: 60 },
  };
  const { source, restore } = loadZoom({ imports, fetchImpl, tmpDir, descriptor });
  try {
    await source.startSource(descriptor);
    source.stopSource(descriptor.id);

    assert.equal(importCalls.length, 1);
    assert.equal(importCalls[0].bytes, audio.length);
    assert.match(importCalls[0].input.originalName, /Standup/);
    assert.equal(importCalls[0].input.contentType, 'audio/mp4');
    assert.equal(importCalls[0].input.captureTime, '2026-07-31T09:00:00.000Z');

    // Second sweep must not re-import.
    await source._sweep(descriptor);
    assert.equal(importCalls.length, 1);
  } finally {
    restore();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
