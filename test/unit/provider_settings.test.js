'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-provider-settings-'));
delete process.env.AI_PROVIDER;
delete process.env.TRANSCRIPTION_PROVIDER;

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const settings = require('../../server/services/settings/provider_settings_service');

migrate();
test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('unconfigured defaults require separately deployed compatible endpoints', () => {
  const runtime = settings.getRuntime();
  assert.equal(runtime.llm.provider, 'openai_compatible');
  assert.equal(runtime.transcription.provider, 'openai-compatible');
  assert.equal(runtime.llm.baseUrl, null);
  assert.equal(runtime.transcription.baseUrl, null);
});

test('admin provider keys are encrypted and never returned', () => {
  const result = settings.update({
    llm: {
      provider: 'openai_compatible', model: 'external-memory-model', baseUrl: 'http://llm.internal/v1',
      apiKey: 'llm-secret-value',
    },
    transcription: {
      provider: 'openai-compatible', model: null,
      baseUrl: 'http://speech.internal/v1/audio/transcriptions', language: 'de', responseFormat: 'verbose_json',
      apiKey: 'speech-secret-value',
    },
  });
  assert.equal(result.llm.apiKey, undefined);
  assert.equal(result.transcription.apiKey, undefined);
  assert.equal(result.llm.apiKeyConfigured, true);
  assert.equal(result.transcription.language, 'de');
  const stored = getDatabase().prepare("SELECT group_concat(value_json, ' ') value FROM app_settings WHERE key LIKE 'providers.%.api_key.%'").get().value;
  assert.doesNotMatch(stored, /llm-secret-value|speech-secret-value/);
  assert.equal(settings.getRuntime().llm.apiKey, 'llm-secret-value');
  assert.equal(settings.getRuntime().transcription.apiKey, 'speech-secret-value');
});

test('model discovery returns provider data without maintaining a model-name list', async () => {
  const originalFetch = global.fetch;
  global.fetch = async (url, options) => {
    assert.equal(String(url), 'https://api.x.ai/v1/models');
    assert.equal(options.headers.Authorization, 'Bearer xai-key');
    return new Response(JSON.stringify({ data: [{ id: 'grok-current' }, { id: 'grok-next' }] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  };
  try {
    const result = await settings.discoverModels({ workload: 'llm', provider: 'xai', apiKey: 'xai-key' });
    assert.deepEqual(result.models, ['grok-current', 'grok-next']);
  } finally {
    global.fetch = originalFetch;
  }
});

test('custom transcription sends the configured multipart language and verbose response format', async () => {
  settings.update({ transcription: {
    provider: 'openai-compatible', model: null,
    baseUrl: 'http://speech.internal/v1/audio/transcriptions', language: 'de', responseFormat: 'verbose_json',
  } });
  const filename = path.join(process.env.NEORECALL_HOME, 'aufnahme.m4a');
  fs.writeFileSync(filename, Buffer.from('audio'));
  const originalFetch = global.fetch;
  global.fetch = async (url, options) => {
    assert.equal(String(url), 'http://speech.internal/v1/audio/transcriptions');
    assert.equal(options.method, 'POST');
    assert.equal(options.body.get('language'), 'de');
    assert.equal(options.body.get('response_format'), 'verbose_json');
    assert.equal(options.body.get('model'), null);
    assert.equal(options.body.get('file').name, 'chunk.m4a');
    return new Response(JSON.stringify({ language: 'de', segments: [{ start: 0, end: 1, text: 'Aufnahme' }] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  };
  try {
    const { OpenAICompatibleProvider } = require('../../server/transcription/providers/openai_compatible_provider');
    const segments = await new OpenAICompatibleProvider().transcribe({ filename });
    assert.equal(segments[0].text, 'Aufnahme');
  } finally {
    global.fetch = originalFetch;
  }
});

test('reset removes admin overrides and their encrypted keys', () => {
  const result = settings.clearOverrides();
  assert.equal(result.llm.provider, 'openai_compatible');
  assert.equal(result.transcription.provider, 'openai-compatible');
  assert.equal(getDatabase().prepare("SELECT COUNT(*) count FROM app_settings WHERE key LIKE 'providers.%'").get().count, 0);
});
