'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-local-providers-'));
process.env.NEORECALL_HOME = home;
delete process.env.AI_PROVIDER;
delete process.env.TRANSCRIPTION_PROVIDER;

const probe = net.createServer();
const port = new Promise((resolve) => probe.listen(0, '127.0.0.1', () => { const { port: free } = probe.address(); probe.close(() => resolve(free)); }));

const { migrate } = require('../../server/db/migrate');
const { closeDatabase, getDatabase } = require('../../server/db/database');
const { getConfig } = require('../../server/config');
const settings = require('../../server/services/settings/provider_settings_service');
const manifestModule = require('../../server/local_runtime/manifest');
const limits = require('../../server/ai/model_limits');
const localLlm = require('../../server/ai/local_llm');
const localProvider = require('../../server/ai/providers/local_provider');
const localModels = require('../../server/services/settings/local_models_service');

const manifest = manifestModule.load();
const platform = manifestModule.platformKey();
const supported = Boolean(manifestModule.component(manifest, 'gemma-2-2b-it').platforms[platform]);

test.before(async () => { process.env.NEORECALL_LOCAL_LLM_PORT = String(await port); migrate(); });
test.after(async () => {
  await localLlm.reset();
  closeDatabase();
  fs.rmSync(home, { recursive: true, force: true });
});

test('both local providers are offered, marked local, and name the component to install', () => {
  const { catalogs } = settings.getAdmin();
  const whistle = catalogs.transcription.find((entry) => entry.id === 'whistle-local');
  const gemma = catalogs.llm.find((entry) => entry.id === 'gemma-local');
  assert.deepEqual([whistle.local, whistle.component, whistle.apiKeyRequired], [true, 'whistle', false]);
  assert.deepEqual([gemma.local, gemma.component, gemma.apiKeyRequired], [true, 'gemma-2-2b-it', false]);
  assert.equal(catalogs.llm.filter((entry) => entry.local).length, 1, 'external providers are not local');
});

test('selecting Whistle checks the language against what the model reads', { skip: !supported && 'no runtime for this platform' }, () => {
  assert.throws(() => settings.update({ transcription: { provider: 'whistle-local', language: 'ja' } }), { code: 'LOCAL_PROVIDER_LANGUAGE_UNSUPPORTED' });
  const saved = settings.update({ transcription: { provider: 'whistle-local', language: 'de-DE' } });
  assert.equal(saved.transcription.provider, 'whistle-local');
  assert.equal(saved.transcription.protocol, 'local');
  assert.equal(saved.transcription.model, 'whistle');
  assert.equal(saved.transcription.baseUrl, null);
});

test('the local language model resolves to loopback with a key nobody has to enter or store', { skip: !supported && 'no runtime for this platform' }, () => {
  const saved = settings.update({ llm: { provider: 'gemma-local' } });
  assert.equal(saved.llm.apiKey, undefined, 'the key is never returned');
  assert.equal(saved.llm.apiKeyConfigured, true);
  const runtime = settings.getRuntime().llm;
  assert.equal(runtime.baseUrl, `http://127.0.0.1:${getConfig().localLlmPort}/v1`);
  assert.equal(runtime.model, 'gemma-2-2b-it');
  assert.ok(runtime.apiKey && runtime.apiKey.length >= 32);
  assert.equal(settings.getRuntime().llm.apiKey, runtime.apiKey, 'both server processes derive the same key');
  const stored = getDatabase().prepare("SELECT group_concat(value_json,' ') value FROM app_settings").get().value;
  assert.equal(stored.includes(runtime.apiKey), false, 'and it is not in the database');
});

test('a local model lowers the budgets to what it can hold, and only ever lowers them', { skip: !supported && 'no runtime for this platform' }, () => {
  const config = getConfig();
  assert.equal(limits.contextSize(), 8192);
  assert.equal(limits.consolidationOutputTokens(), 2500);
  assert.equal(limits.previewOutputTokens(), Math.min(config.aiPreviewMaxOutputTokens, 1024));
  assert.ok(limits.contextSize() < config.llmContextSize);
  settings.update({ llm: { provider: 'openai_compatible', model: 'external', baseUrl: 'http://llm.internal/v1' } });
  assert.equal(limits.contextSize(), config.llmContextSize, 'an external model keeps the configured budgets');
  assert.equal(limits.consolidationOutputTokens(), config.aiConsolidationMaxOutputTokens);
  settings.update({ llm: { provider: 'gemma-local' } });
});

test('Gemma has no system role, so instructions move into the first user message', () => {
  const folded = localProvider.foldSystemIntoUser([
    { role: 'system', content: 'Be brief.' }, { role: 'system', content: 'Answer in German.' }, { role: 'user', content: 'Question?' },
  ]);
  assert.deepEqual(folded, [{ role: 'user', content: 'Be brief.\n\nAnswer in German.\n\nQuestion?' }]);
  assert.deepEqual(localProvider.foldSystemIntoUser([{ role: 'user', content: 'x' }]), [{ role: 'user', content: 'x' }]);
  assert.deepEqual(localProvider.foldSystemIntoUser([{ role: 'system', content: 's' }, { role: 'user', content: [{ type: 'text', text: 'a' }] }]),
    [{ role: 'user', content: [{ type: 'text', text: 's' }, { type: 'text', text: 'a' }] }]);
});

// Makes the installer believe Gemma is installed: the pinned file sizes with
// sparse files (the model is 1.7 GB), the fake server where llama-server would be,
// and a state file under the manifest's own fingerprint.
function pretendInstalled() {
  const installer = localLlm.getInstaller();
  const entry = manifestModule.component(manifest, 'gemma-2-2b-it');
  const weights = entry.files[0];
  const weightsPath = installer.pathOf('weights');
  fs.mkdirSync(path.dirname(weightsPath), { recursive: true });
  fs.closeSync(fs.openSync(weightsPath, 'w'));
  fs.truncateSync(weightsPath, weights.size);
  const serverPath = installer.pathOf('server');
  fs.mkdirSync(path.dirname(serverPath), { recursive: true });
  fs.copyFileSync(path.join(__dirname, '..', 'fixtures', 'fake_llama_server.js'), serverPath);
  fs.chmodSync(serverPath, 0o755);
  fs.writeFileSync(path.join(installer.directory, 'state.json'), JSON.stringify({ phase: 'installed', verifiedFingerprint: manifestModule.fingerprint(entry, entry.platforms[platform]) }));
  return installer;
}

test('a request through the real provider reaches the local server, waits for it, and sends no system role', { skip: !supported && 'no runtime for this platform' }, async () => {
  const installer = localLlm.getInstaller();
  assert.equal(localProvider.ready(), false, 'not ready before it is installed');
  assert.equal(installer.status().phase, 'not_installed');
  pretendInstalled();
  assert.equal(installer.isInstalled(), true);
  assert.equal(localProvider.ready(), true);

  // The worker process is the one that keeps the server running.
  await localLlm.maintain({ selected: true });
  const schema = { type: 'object', additionalProperties: false, required: ['answer'], properties: { answer: { type: 'string', maxLength: 50 } } };
  const response = await localProvider.chatJSON({
    userId: null, purpose: 'ask', maxTokens: 64,
    messages: [{ role: 'system', content: 'You answer with JSON.' }, { role: 'user', content: 'Say ready.' }],
    responseFormat: { type: 'json_schema', json_schema: { name: 't', strict: true, schema } },
  });
  assert.equal(response.value.answer, 'ready');
  const sent = response.value.received;
  assert.equal(sent.model, 'gemma-2-2b-it');
  assert.deepEqual(sent.messages, [{ role: 'user', content: 'You answer with JSON.\n\nSay ready.' }]);
  assert.equal(JSON.stringify(sent.response_format).includes('maxLength'), false, 'grammar-hostile keywords are stripped');
  const row = getDatabase().prepare("SELECT provider, model, state FROM ai_requests ORDER BY reserved_at DESC LIMIT 1").get();
  assert.deepEqual({ ...row }, { provider: 'gemma-local', model: 'gemma-2-2b-it', state: 'succeeded' });

  // Switching to another provider takes the server down with it.
  await localLlm.maintain({ selected: false });
  await assert.rejects(fetch(`http://127.0.0.1:${getConfig().localLlmPort}/health`));
});

test('the admin view lists every local model with its selection and install state', { skip: !supported && 'no runtime for this platform' }, () => {
  const models = localModels.status();
  assert.deepEqual(models.map((model) => model.id).sort(), ['gemma-2-2b-it', 'whistle']);
  const gemma = models.find((model) => model.id === 'gemma-2-2b-it');
  assert.equal(gemma.workload, 'llm');
  assert.equal(gemma.selected, true);
  assert.equal(gemma.phase, 'installed');
  assert.equal(gemma.license, 'Gemma Terms of Use');
  assert.equal(models.find((model) => model.id === 'whistle').selected, true);
  assert.throws(() => localModels.install('nonexistent'), { code: 'LOCAL_MODEL_NOT_FOUND' });
});
