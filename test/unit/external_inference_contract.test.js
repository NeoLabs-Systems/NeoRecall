'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const providerSettings = require('../../server/services/settings/provider_settings_service');
const { transcriptionEndpoint } = require('../../server/transcription/providers/openai_compatible_provider');

test('NeoRecall exposes no in-process LLM or transcription provider', () => {
  assert.equal(Object.values(providerSettings.LLM_PROVIDERS).some((provider) => provider.protocol === 'local'), false);
  assert.equal(Object.values(providerSettings.TRANSCRIPTION_PROVIDERS).some((provider) => provider.protocol === 'local'), false);
  const packageJson = JSON.parse(fs.readFileSync(path.join(__dirname, '../../package.json')));
  assert.equal(packageJson.optionalDependencies, undefined);
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
