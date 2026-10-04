'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { WhistleRuntime } = require('../../server/transcription/local_asr/runtime');

const config = { localAsrStartTimeoutMs: 3_000, localAsrRequestTimeoutMs: 400, localRestartBaseMs: 40, localRestartMaxMs: 200 };
const worker = path.join(__dirname, '..', 'fixtures', 'fake_whistle_worker.js');
const files = { python: process.execPath, worker, library: 'unused', weights: 'unused' };
const samples = Buffer.alloc(64).toString('base64');

async function started(overrides = {}) {
  const runtime = new WhistleRuntime({ files, config, ...overrides });
  runtime.ensureStarted();
  await runtime.whenSettled();
  return runtime;
}

async function until(condition, ms = 3_000) {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('condition not reached');
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

test('becomes ready when the worker says so and answers requests', async () => {
  const runtime = await started();
  assert.equal(runtime.isReady(), true);
  const result = await runtime.transcribe({ samples, wordTimestamps: true });
  assert.equal(result.text, 'hello world.');
  await runtime.stop();
  assert.equal(runtime.state, 'stopped');
});

test('requests run one at a time even when issued together', async () => {
  const runtime = await started();
  const results = await Promise.all([1, 2, 3, 4].map(() => runtime.transcribe({ samples })));
  assert.equal(results.length, 4, 'the worker rejects overlapping requests, so none overlapped');
  await runtime.stop();
});

test('a worker that stops answering is replaced, and the next request succeeds', async () => {
  const runtime = await started();
  await assert.rejects(runtime.transcribe({ samples, language: 'hang' }), { code: 'LOCAL_ASR_TIMEOUT' });
  await until(() => runtime.isReady() && runtime.child);
  assert.equal((await runtime.transcribe({ samples })).text, 'hello world.');
  await runtime.stop();
});

test('a crash fails the request that was running and the worker comes back by itself', async () => {
  const runtime = await started();
  const firstChild = runtime.child;
  await assert.rejects(runtime.transcribe({ samples, language: 'crash' }), { code: 'LOCAL_ASR_WORKER_EXITED' });
  await until(() => runtime.isReady() && runtime.child && runtime.child !== firstChild);
  assert.equal((await runtime.transcribe({ samples })).text, 'hello world.');
  await runtime.stop();
});

test('requests while the worker is down fail as retryable instead of waiting forever', async () => {
  const runtime = new WhistleRuntime({ files, config });
  await assert.rejects(runtime.transcribe({ samples }), { code: 'LOCAL_ASR_UNAVAILABLE', retryable: true });
});

test('a worker that cannot load reports why and backs off instead of spinning', async () => {
  const fatal = { ...files, worker: path.join(__dirname, '..', 'fixtures', 'fake_whistle_worker_fatal.js') };
  const runtime = new WhistleRuntime({ files: fatal, config: { ...config, localRestartBaseMs: 60, localRestartMaxMs: 400 } });
  try {
    runtime.ensureStarted();
    await runtime.whenSettled();
    assert.equal(runtime.isReady(), false);
    assert.match(runtime.lastError.message, /corrupt/);
    assert.equal(runtime.state, 'backoff');
    const first = runtime.retryAt;
    await until(() => runtime.retryAt !== first);
    assert.ok(runtime.backoffMs >= 120, 'the delay doubles while failures continue');
  } finally {
    await runtime.stop();
  }
});

test('a health check on an idle, healthy worker changes nothing', async () => {
  const runtime = await started();
  assert.equal(await runtime.healthCheck(), undefined);
  assert.equal(runtime.isReady(), true);
  await runtime.stop();
});
