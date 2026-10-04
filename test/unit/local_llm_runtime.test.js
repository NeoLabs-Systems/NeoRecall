'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const path = require('node:path');
const { LlamaRuntime } = require('../../server/ai/local_llm/runtime');

const config = { localLlmStartTimeoutMs: 5_000, localRestartBaseMs: 40, localRestartMaxMs: 200 };
const server = path.join(__dirname, '..', 'fixtures', 'fake_llama_server.js');

function freePort() {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
}

async function runtime(overrides = {}) {
  const port = overrides.port ?? await freePort();
  return new LlamaRuntime({
    files: { server, weights: '/models/gemma.gguf' }, config, port, apiKey: 'secret-key', contextSize: 8192,
    alias: 'gemma-2-2b-it', idleSeconds: 600, ...overrides,
  });
}

async function until(condition, ms = 5_000) {
  const deadline = Date.now() + ms;
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error('condition not reached');
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
}

test('is ready once /health answers, with the context fixed to what the model holds', async () => {
  const llama = await runtime();
  llama.ensureStarted();
  assert.equal(llama.isReady(), false, 'loading is not ready');
  await llama.whenSettled();
  assert.equal(llama.isReady(), true);
  const { args } = await (await fetch(`http://127.0.0.1:${llama.port}/_args`)).json();
  const value = (flag) => args[args.indexOf(flag) + 1];
  assert.equal(value('--ctx-size'), '8192');
  assert.equal(value('--parallel'), '1', 'one slot, so the context is not divided between requests');
  assert.equal(value('--host'), '127.0.0.1', 'loopback only');
  assert.equal(value('--api-key'), 'secret-key');
  assert.equal(value('--sleep-idle-seconds'), '600', 'the model unloads itself when idle');
  await llama.stop();
});

test('idle unloading can be turned off', async () => {
  const llama = await runtime({ idleSeconds: 0 });
  llama.ensureStarted();
  await llama.whenSettled();
  const { args } = await (await fetch(`http://127.0.0.1:${llama.port}/_args`)).json();
  assert.equal(args.includes('--sleep-idle-seconds'), false);
  await llama.stop();
});

test('a request waits out a server that is still loading, and fails as retryable if none comes up', async () => {
  const llama = await runtime();
  llama.ensureStarted();
  await llama.waitUntilServing(3_000);
  await llama.stop();
  const absent = await runtime();
  await assert.rejects(absent.waitUntilServing(300), { code: 'LOCAL_LLM_UNAVAILABLE', retryable: true });
});

test('a server left running by a killed worker is adopted instead of fought over the port', async () => {
  const orphan = await runtime();
  orphan.ensureStarted();
  await orphan.whenSettled();
  const next = await runtime({ port: orphan.port });
  assert.equal(await next.adoptable(), true);
  assert.equal(await orphan.adoptable(), false, 'a server this process runs is not "adopted"');
  await orphan.stop();
  assert.equal(await next.adoptable(), false, 'nothing answers once it is gone');
});

test('a server that stops answering is replaced only after repeated failed checks', async () => {
  const llama = await runtime();
  llama.ensureStarted();
  await llama.whenSettled();
  const first = llama.child;
  await fetch(`http://127.0.0.1:${llama.port}/_stop-answering`);
  await llama.healthCheck();
  await llama.healthCheck();
  assert.equal(llama.child, first, 'two misses could be a model waking up');
  await llama.healthCheck();
  assert.equal(llama.isReady(), false, 'the third replaces it');
  await until(() => llama.isReady() && llama.child !== first);
  await llama.stop();
});
