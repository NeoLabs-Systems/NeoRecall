'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const providerSettings = require('../../server/services/settings/provider_settings_service');
const { transcriptionEndpoint } = require('../../server/transcription/providers/openai_compatible_provider');

test('NeoRecall exposes no in-process LLM or transcription provider', () => {
  // Recognition and generation are always somebody else's endpoint: there is no
  // provider a user could pick that would run either one in this process.
  assert.equal(Object.values(providerSettings.LLM_PROVIDERS).some((provider) => provider.protocol === 'local'), false);
  assert.equal(Object.values(providerSettings.TRANSCRIPTION_PROVIDERS).some((provider) => provider.protocol === 'local'), false);
  // The one native dependency that remains carries speech detection and
  // diarization, and it is optional precisely because it must never be load
  // bearing: a platform without a build still transcribes, just without
  // speaker labels.
  const packageJson = JSON.parse(fs.readFileSync(path.join(__dirname, '../../package.json')));
  assert.deepEqual(Object.keys(packageJson.optionalDependencies || {}), ['sherpa-onnx-node']);
  assert.equal(Object.keys(packageJson.dependencies).some((name) => /llama|whisper|onnxruntime/.test(name)), false,
    'nothing that recognizes speech or generates text may be a hard dependency');
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
