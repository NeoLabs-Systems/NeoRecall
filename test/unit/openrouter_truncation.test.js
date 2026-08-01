'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-truncation-'));
process.env.OPENROUTER_API_KEY = 'test-key';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const provider = require('../../server/ai/providers/openrouter_provider');
const { VALIDATION_FAILURE_CODES } = require('../../server/services/memories/consolidation_service');

migrate();
let server;
test.after(() => { server?.close(); closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

/// Answers once with whatever body the test supplies.
async function respondWith(body) {
  server?.close();
  server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(body)); });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  process.env.OPENROUTER_BASE_URL = `http://127.0.0.1:${server.address().port}`;
}

test('a completion stopped at the token limit is reported as truncation, not as bad JSON', async () => {
  // Exactly what a reasoning model returns when its internal tokens consumed the
  // budget: HTTP 200, an ordinary body, and JSON that simply stops. Parsing it
  // yields a syntax error that looks like a transport fault, which points at
  // none of the things that would actually fix it.
  await respondWith({
    id: 'truncated-1',
    usage: { prompt_tokens: 20143, completion_tokens: 15979, completion_tokens_details: { reasoning_tokens: 12307 } },
    choices: [{ finish_reason: 'length', message: { content: '{"conversationSections":[{"titleEn":"Tax classi' } }],
  });

  await assert.rejects(
    () => provider.chatJSON({ userId: null, purpose: 'consolidation', model: 'test/model', messages: [{ role: 'user', content: '{}' }] }),
    (error) => {
      assert.equal(error.code, 'AI_OUTPUT_TRUNCATED');
      assert.equal(error.completionTokens, 15979);
      assert.equal(error.reasoningTokens, 12307, 'The reasoning share is what explains the missing budget.');
      return true;
    },
  );
  const request = getDatabase().prepare("SELECT state,error_code FROM ai_requests WHERE id IS NOT NULL ORDER BY reserved_at DESC LIMIT 1").get();
  assert.equal(request.state, 'failed');
  assert.equal(request.error_code, 'AI_OUTPUT_TRUNCATED');
});

test('a provider error inside an HTTP 200 is surfaced with its own reason, not as an empty response', async () => {
  // OpenRouter can answer 200 with an error object in the body; reading that as
  // "no message content" hides the one line that explains the failure.
  await respondWith({ id: 'err-1', error: { message: 'Provider returned error', code: 502 } });
  await assert.rejects(
    () => provider.chatJSON({ userId: null, purpose: 'consolidation', model: 'test/model', messages: [{ role: 'user', content: '{}' }] }),
    (error) => {
      assert.equal(error.code, 'AI_PROVIDER_ERROR');
      assert.equal(error.providerCode, 502);
      assert.match(error.message, /Provider returned error/);
      return true;
    },
  );
});

test('a complete answer is still parsed normally', async () => {
  await respondWith({
    id: 'complete-1',
    usage: { prompt_tokens: 10, completion_tokens: 10 },
    choices: [{ finish_reason: 'stop', message: { content: '{"ok":true}' } }],
  });
  const response = await provider.chatJSON({ userId: null, purpose: 'consolidation', model: 'test/model', messages: [{ role: 'user', content: '{}' }] });
  assert.deepEqual(response.value, { ok: true });
});

test('truncation narrows the next consolidation instead of being retried unchanged', () => {
  // The input asked for more answer than the budget allows, so resending it
  // reproduces the failure; carrying fewer conversations is the remedy.
  assert.ok(VALIDATION_FAILURE_CODES.includes('AI_OUTPUT_TRUNCATED'));
});

const ai = require('../../server/ai/ai_engine');

test('a transient consolidation failure is retried, a contract violation is not', async () => {
  // Measured against the live model: two of seven real requests failed on the
  // first attempt for reasons that say nothing about the input. Without a retry
  // each one costs a paid request and postpones every memory.
  assert.deepEqual([...ai.TRANSIENT_AI_CODES].sort(),
    ['AI_EMPTY_RESPONSE', 'AI_HTTP_ERROR', 'AI_PROVIDER_ERROR', 'AI_REQUEST_FAILED', 'AI_TIMEOUT']);
  for (const contractViolation of ['AI_SCHEMA_INVALID', 'AI_REFERENCE_INVALID', 'AI_TEMPORAL_INVALID', 'AI_OUTPUT_TRUNCATED']) {
    assert.equal(ai.TRANSIENT_AI_CODES.includes(contractViolation), false,
      `${contractViolation} must not be retried unchanged; resending reproduces it.`);
  }
});

test('a consolidation whose first answer is empty succeeds on the retry', async () => {
  let calls = 0;
  server?.close();
  server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      calls += 1;
      res.setHeader('Content-Type', 'application/json');
      // First attempt: a reasoning model that produced no answer at all.
      const content = calls === 1 ? null : JSON.stringify({
        conversationSections: [{ titleEn: 'T', summaryEn: 'S', memoryWorthy: false, topics: [], sourceSegmentIds: ['s1'] }],
        entities: [], memories: [], dailySummary: null,
      });
      res.end(JSON.stringify({ id: `r${calls}`, usage: {}, choices: [{ finish_reason: 'stop', message: { content } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  process.env.OPENROUTER_BASE_URL = `http://127.0.0.1:${server.address().port}`;

  const result = await ai.consolidate(null, {
    conversations: [{ id: 'c1', sessionId: 's1', startedAt: '2026-08-01T10:00:00.000Z', endedAt: '2026-08-01T10:30:00.000Z',
      segments: [{ id: 'seg-1', started_at: '2026-08-01T10:00:00.000Z', ended_at: '2026-08-01T10:30:00.000Z', text: 'Hello', language: 'en', speakerClusterId: null }] }],
    previousDailySummary: null, timezone: 'UTC',
  });
  assert.equal(calls, 2, 'The empty first answer should have been retried.');
  assert.equal(result.value.conversationSections[0].titleEn, 'T');
});
