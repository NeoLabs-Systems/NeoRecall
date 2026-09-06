'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-provider-settings-'));
delete process.env.AI_PROVIDER;
delete process.env.TRANSCRIPTION_PROVIDER;

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const settings = require('../../server/services/settings/provider_settings_service');

migrate();
let chatServer = null;
const chatRequests = [];

/// A real endpoint on loopback.
///
/// The provider sends chat completions over HTTP with its own timeouts rather
/// than through global fetch, so a stub on fetch would intercept nothing. The
/// handler receives each parsed request body and returns { status, body }.
async function chatEndpoint(handler) {
  await new Promise((resolve) => (chatServer ? chatServer.close(resolve) : resolve()));
  chatRequests.length = 0;
  chatServer = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      chatRequests.push(body);
      const reply = handler(body, chatRequests.length);
      response.statusCode = reply.status || 200;
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify(reply.body));
    });
  });
  await new Promise((resolve) => chatServer.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${chatServer.address().port}/v1`;
}

test.after(() => {
  chatServer?.close();
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
    assert.equal(options.body.get('prompt'), 'NeoRecall, Grace Hopper');
    assert.equal(options.body.get('model'), null);
    assert.equal(options.body.get('file').name, 'chunk.m4a');
    return new Response(JSON.stringify({ language: 'de', segments: [{ start: 0, end: 1, text: 'Aufnahme' }] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  };
  try {
    const { OpenAICompatibleProvider } = require('../../server/transcription/providers/openai_compatible_provider');
    const segments = await new OpenAICompatibleProvider().transcribe({ filename, vocabulary: ['NeoRecall', 'Grace Hopper'] });
    assert.equal(segments[0].text, 'Aufnahme');
  } finally {
    global.fetch = originalFetch;
  }
});

test('Deepgram sends vocabulary as repeated Nova-3 keyterms', async () => {
  settings.update({ transcription: {
    provider: 'deepgram', model: 'nova-3', baseUrl: 'https://api.deepgram.com', apiKey: 'deepgram-key',
  } });
  const filename = path.join(process.env.NEORECALL_HOME, 'deepgram.wav');
  fs.writeFileSync(filename, Buffer.from('audio'));
  const originalFetch = global.fetch;
  global.fetch = async (url) => {
    const parsed = new URL(String(url));
    assert.deepEqual(parsed.searchParams.getAll('keyterm'), ['NeoRecall', 'Grace Hopper']);
    assert.deepEqual(parsed.searchParams.getAll('keywords'), []);
    return new Response(JSON.stringify({ results: { channels: [{ alternatives: [{ transcript: 'NeoRecall', words: [] }] }] } }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  };
  try {
    const { DeepgramProvider } = require('../../server/transcription/providers/deepgram_provider');
    assert.equal((await new DeepgramProvider().transcribe({ filename, vocabulary: ['NeoRecall', 'Grace Hopper'] }))[0].text, 'NeoRecall');
  } finally { global.fetch = originalFetch; }
});

test('AssemblyAI sends vocabulary through its native keyterms prompt', async () => {
  settings.update({ transcription: {
    provider: 'assemblyai', model: null, baseUrl: 'https://api.assemblyai.com', apiKey: 'assembly-key',
  } });
  const filename = path.join(process.env.NEORECALL_HOME, 'assembly.wav');
  fs.writeFileSync(filename, Buffer.from('audio'));
  const originalFetch = global.fetch;
  let call = 0;
  global.fetch = async (_url, options) => {
    call += 1;
    if (call === 1) return new Response(JSON.stringify({ upload_url: 'https://upload.invalid/audio' }), { status: 200 });
    const body = JSON.parse(options.body);
    assert.deepEqual(body.keyterms_prompt, ['NeoRecall', 'Grace Hopper']);
    return new Response(JSON.stringify({ id: 'transcript', status: 'completed', text: 'NeoRecall', words: [] }), { status: 200 });
  };
  try {
    const { AssemblyAIProvider } = require('../../server/transcription/providers/assemblyai_provider');
    assert.equal((await new AssemblyAIProvider().transcribe({ filename, vocabulary: ['NeoRecall', 'Grace Hopper'] }))[0].text, 'NeoRecall');
  } finally { global.fetch = originalFetch; }
});

test('reset removes admin overrides and their encrypted keys', () => {
  const result = settings.clearOverrides();
  assert.equal(result.llm.provider, 'openai_compatible');
  assert.equal(result.transcription.provider, 'openai-compatible');
  assert.equal(getDatabase().prepare("SELECT COUNT(*) count FROM app_settings WHERE key LIKE 'providers.%'").get().count, 0);
});

test('turning off thinking is stored, resolved, and actually sent', async () => {
  const baseUrl = await chatEndpoint(() => ({
    body: { id: 'r', usage: {}, choices: [{ finish_reason: 'stop', message: { content: '{"answer":"ready"}' } }] },
  }));
  settings.update({ llm: {
    provider: 'openai_compatible', model: 'Qwen3.5-4B', baseUrl,
    extraBody: { chat_template_kwargs: { enable_thinking: false } },
  } });
  const stored = settings.getAdmin().llm;
  assert.deepEqual(stored.extraBody, { chat_template_kwargs: { enable_thinking: false } });
  assert.equal(stored.sources.extraBody, 'admin');

  const provider = require('../../server/ai/providers/openai_compatible_provider');
  await provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }] });
  assert.deepEqual(chatRequests[0].chat_template_kwargs, { enable_thinking: false });
  assert.equal(chatRequests[0].model, 'Qwen3.5-4B');
});

test('extra request JSON must be an object, not any JSON value', () => {
  assert.throws(() => settings.update({ llm: {
    provider: 'openai_compatible', model: 'm', baseUrl: 'http://gpu.internal/v1', extraBody: 'enable_thinking=false',
  } }), /VALIDATION_ERROR|invalid/i);
});

test('a truncated reasoning model is retried without its thinking step rather than failed', async () => {
  // The failure that matters most where it hurts most: consolidation reads
  // truncation as the input's fault, narrows the batch and eventually
  // quarantines the conversation. A model that always deliberates would work
  // through an entire backlog that way, so one more attempt without the
  // deliberation beats giving up.
  const baseUrl = await chatEndpoint((body) => (
    // Thinking on: burns the budget deliberating and never answers.
    body.chat_template_kwargs?.enable_thinking !== false
      ? { body: { id: 'r1', usage: { completion_tokens: 400, completion_tokens_details: { reasoning_tokens: 397 } },
          choices: [{ finish_reason: 'length', message: { content: '{"ans' } }] } }
      : { body: { id: 'r2', usage: {}, choices: [{ finish_reason: 'stop', message: { content: '{"answer":"ready"}' } }] } }
  ));
  settings.update({ llm: { provider: 'openai_compatible', model: 'Qwen3.5-4B', baseUrl, extraBody: null } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  const result = await provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }] });
  assert.deepEqual(result.value, { answer: 'ready' }, 'the second attempt is what the caller gets');
  assert.equal(chatRequests.length, 2, 'exactly one extra attempt, not a loop');
  assert.equal(chatRequests[0].chat_template_kwargs, undefined,
    'a provider that has never heard of the field is not sent it speculatively');
  assert.deepEqual(chatRequests[1].chat_template_kwargs, { enable_thinking: false });
});

test('a model that truncates even without thinking still reports truncation', async () => {
  // The rescue must not turn a real budget problem into a mystery.
  const baseUrl = await chatEndpoint(() => ({
    body: { id: 'r', usage: { completion_tokens: 400 }, choices: [{ finish_reason: 'length', message: { content: '{' } }] },
  }));
  settings.update({ llm: { provider: 'openai_compatible', model: 'm', baseUrl, extraBody: null } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  await assert.rejects(
    () => provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }] }),
    (error) => { assert.equal(error.code, 'AI_OUTPUT_TRUNCATED'); return true; },
  );
  assert.equal(chatRequests.length, 2, 'it tries the rescue once and then stops');
});

test('an operator who already disabled thinking is not retried behind their back', async () => {
  const baseUrl = await chatEndpoint(() => ({
    body: { id: 'r', usage: {}, choices: [{ finish_reason: 'length', message: { content: '{' } }] },
  }));
  settings.update({ llm: { provider: 'openai_compatible', model: 'm', baseUrl,
    extraBody: { chat_template_kwargs: { enable_thinking: false } } } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  await assert.rejects(() => provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }] }));
  assert.equal(chatRequests.length, 1, 'there is nothing left to try, so it does not waste a request');
});

test('a prompt that does not fit is not mistaken for a transport fault', async () => {
  // The two are handled in opposite ways. A transport fault is retried; a prompt
  // that is too long produces the identical rejection every time. Classified as
  // transient it was retried, failed the run without narrowing or quarantining,
  // re-entered the candidate set on the next tick and did it again — forever,
  // never producing a memory. It has to be a validation failure so the batch
  // narrows and the conversation is eventually set aside.
  const baseUrl = await chatEndpoint(() => ({
    status: 400,
    body: { error: { code: 'context_length_exceeded',
      message: "This model's maximum context length is 8192 tokens, however you requested 12000." } },
  }));
  settings.update({ llm: { provider: 'openai_compatible', model: 'm', baseUrl, extraBody: null } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  await assert.rejects(
    () => provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }] }),
    (error) => {
      assert.equal(error.code, 'AI_CONTEXT_EXCEEDED', 'not AI_HTTP_ERROR, which the pipeline would retry');
      assert.match(error.message, /LLM_CONTEXT_SIZE/, 'and it names the setting that is wrong');
      return true;
    },
  );
  assert.equal(chatRequests.length, 1, 'resending an oversized prompt cannot help, so it is not resent');

  const { TRANSIENT_AI_CODES } = require('../../server/ai/ai_engine');
  const { VALIDATION_FAILURE_CODES } = require('../../server/services/memories/consolidation_service');
  assert.equal(TRANSIENT_AI_CODES.includes('AI_CONTEXT_EXCEEDED'), false);
  assert.ok(VALIDATION_FAILURE_CODES.includes('AI_CONTEXT_EXCEEDED'),
    'so consolidation narrows the batch and eventually quarantines rather than looping');
});

test('an ordinary bad request is still a transport fault worth retrying', () => {
  const { contextOverflow } = require('../../server/ai/providers/openai_compatible_provider');
  assert.equal(contextOverflow(400, {}, 'Invalid API key provided'), false);
  assert.equal(contextOverflow(429, {}, 'rate limit exceeded'), false);
  assert.equal(contextOverflow(400, {}, 'the request exceeds the available context size'), true);
});

test('retrieved evidence is trimmed to what the model can read, worst matches first', () => {
  const { contextWithinBudget } = require('../../server/ai/ai_engine');
  // Search returns best-first, so what has to go is the tail.
  const context = Array.from({ length: 16 }, (_, index) => ({ sourceId: `memory:${index}`, text: 'x'.repeat(2_000) }));
  const kept = contextWithinBudget(context, 10_000);
  assert.ok(kept.length > 0 && kept.length < context.length, 'some evidence is dropped, not all of it');
  assert.deepEqual(kept.map((item) => item.sourceId), context.slice(0, kept.length).map((item) => item.sourceId),
    'the best matches are the ones kept');
  // A single oversized item still goes, because answering from one long memory
  // beats refusing to answer.
  assert.equal(contextWithinBudget([{ sourceId: 'a', text: 'y'.repeat(50_000) }], 1_000).length, 1);
});

test('an endpoint that cannot compile the schema still gets a usable answer', async () => {
  // Some builds turn a JSON schema into a grammar and reject what they cannot
  // express. Guessing which keyword offends is a losing game; asking for plain
  // JSON instead is not, because the contract is in the prompt and the answer
  // is validated either way.
  const asked = [];
  const baseUrl = await chatEndpoint((body) => {
    asked.push(body.response_format?.type);
    return body.response_format?.type === 'json_schema'
      ? { status: 400, body: { error: { message: 'Failed to initialize samplers: failed to parse grammar' } } }
      : { body: { id: 'r', usage: {}, choices: [{ finish_reason: 'stop', message: { content: '{"answer":"ready"}' } }] } };
  });
  settings.update({ llm: { provider: 'openai_compatible', model: 'Qwen3.5-4B', baseUrl, extraBody: null } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  const result = await provider.chatJSON({
    userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }],
    responseFormat: { type: 'json_schema', json_schema: { name: 't', strict: true, schema: { type: 'object', properties: { answer: { type: 'string' } } } } },
  });
  assert.deepEqual(result.value, { answer: 'ready' }, 'the caller gets its answer, not a failure');
  assert.deepEqual(asked, ['json_schema', 'json_object'],
    'the schema is tried first and plain JSON is the fallback, never the other way round');
});

test('a refusal that is not about the schema is not papered over', async () => {
  // The fallback must not turn a genuine problem — a bad key, a missing model —
  // into a second wasted request and a confusing error.
  const baseUrl = await chatEndpoint(() => ({
    status: 400, body: { error: { message: 'model "m" not found' } },
  }));
  settings.update({ llm: { provider: 'openai_compatible', model: 'm', baseUrl, extraBody: null } });
  const provider = require('../../server/ai/providers/openai_compatible_provider');
  await assert.rejects(() => provider.chatJSON({
    userId: null, purpose: 'ask', messages: [{ role: 'user', content: '{}' }],
    responseFormat: { type: 'json_schema', json_schema: { name: 't', strict: true, schema: { type: 'object' } } },
  }));
  assert.equal(chatRequests.length, 1, 'no pointless second attempt');
});
