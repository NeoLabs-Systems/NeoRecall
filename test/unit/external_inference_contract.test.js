'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const providerSettings = require('../../server/services/settings/provider_settings_service');
require('../../server/speakers/identity_engine');
const { transcriptionEndpoint } = require('../../server/transcription/providers/openai_compatible_provider');

test('a model that runs on this host does so as a supervised child process, never inside Node', () => {
  const manifest = require('../../models/local_runtimes.json');
  const local = [...Object.values(providerSettings.LLM_PROVIDERS), ...Object.values(providerSettings.TRANSCRIPTION_PROVIDERS)]
    .filter((provider) => provider.protocol === 'local');
  assert.ok(local.length >= 2, 'both workloads offer a local provider');
  for (const provider of local) {
    assert.equal(provider.local, true);
    assert.ok(manifest.components.some((component) => component.id === provider.component), `${provider.label} is pinned in models/local_runtimes.json`);
  }
  // sherpa-onnx-node is optional so a platform without a build still transcribes, just without speaker labels.
  const packageJson = JSON.parse(fs.readFileSync(path.join(__dirname, '../../package.json')));
  assert.deepEqual(Object.keys(packageJson.optionalDependencies || {}), ['sherpa-onnx-node']);
  assert.equal(Object.keys(packageJson.dependencies).some((name) => /llama|whisper|onnxruntime|needle|cactus/.test(name)), false,
    'nothing that recognizes speech or generates text may be a dependency: a native crash in one would take the server with it');
});

test('the code that runs local models reaches for no native package of its own', () => {
  // Each model is a separate program (a Python worker, llama-server) so that a
  // crash, a hang or a leak in one is a restart rather than an outage. A native
  // Node addon would put it back in this process.
  const roots = ['server/local_runtime', 'server/ai/local_llm', 'server/transcription/local_asr'].map((dir) => path.join(__dirname, '../..', dir));
  for (const root of roots) {
    for (const file of fs.readdirSync(root).filter((name) => name.endsWith('.js'))) {
      const source = fs.readFileSync(path.join(root, file), 'utf8');
      const required = [...source.matchAll(/require\('([^']+)'\)/g)].map((match) => match[1]);
      assert.deepEqual(required.filter((name) => !name.startsWith('node:') && !name.startsWith('.')), [], `${file} may only use node built-ins and local modules`);
    }
  }
});

test('audio conditioning stays inside what already ships', () => {
  // Conditioning is deliberately built from the ffmpeg binary the project
  // already depends on. The moment it reaches for a native audio library it
  // becomes a platform requirement for transcription, which is the thing this
  // whole file exists to prevent.
  const source = fs.readFileSync(path.join(__dirname, '../../server/transcription/audio_preprocess.js'), 'utf8');
  const required = [...source.matchAll(/require\('([^']+)'\)/g)].map((match) => match[1]);
  assert.deepEqual(
    required.filter((name) => !name.startsWith('node:') && !name.startsWith('.') && name !== 'ffmpeg-static'),
    [],
    'audio conditioning may only use node built-ins, ffmpeg-static and local modules',
  );
});

test('speaker resolution degrades to nothing rather than failing without the audio runtime', () => {
  // The native runtime is optional, so an installation without it must still
  // transcribe — just with no speaker on the segments. Every job type added for
  // speaker identity has to be reachable and harmless in that configuration, or
  // the optional dependency becomes a required one through the back door.
  const runner = require('../../server/workers/worker_runner');
  for (const type of ['resolve_speakers', 'reconcile_speakers']) {
    const handler = runner.handlerFor(type);
    assert.equal(typeof handler.handle, 'function', `${type} has a handler`);
  }
  // Nothing in the resolution path may pull the native module in at require
  // time; it is reached lazily through local_analysis only when audio is read.
  assert.equal(Object.keys(require.cache).some((file) => file.includes('sherpa-onnx-node')), false,
    'requiring the speaker modules must not load the native runtime');
});

test('custom transcription accepts a version root or a full multipart endpoint', () => {
  assert.equal(
    transcriptionEndpoint('http://192.168.188.251:8090/v1'),
    'http://192.168.188.251:8090/v1/audio/transcriptions',
  );
  assert.equal(
    transcriptionEndpoint('http://192.168.188.251:8090/v1/audio/transcriptions'),
    'http://192.168.188.251:8090/v1/audio/transcriptions',
  );
});
