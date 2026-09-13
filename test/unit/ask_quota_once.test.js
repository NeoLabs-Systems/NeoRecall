'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-ask-quota-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_MODEL = 'test/model';
const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const openai = require('../../server/ai/providers/openai_compatible_provider');
const aiEngine = require('../../server/ai/ai_engine');

test('Ask charges quota once even when the model is retried', async () => {
  let calls = 0;
  let charged = 0;
  const original = openai.chatJSON;
  openai.chatJSON = async () => {
    calls += 1;
    if (calls === 1) throw Object.assign(new Error('timeout'), { code: 'AI_TIMEOUT' });
    return { requestId: 'ask-retry', value: { answer: 'Nothing recorded.', citations: [] } };
  };
  try {
    const result = await aiEngine.answer('quota-user', 'What happened today?', [], () => { charged += 1; });
    assert.equal(result.value.answer, 'Nothing recorded.');
    assert.equal(calls, 2);
    assert.equal(charged, 1);
  } finally {
    openai.chatJSON = original;
  }
});
