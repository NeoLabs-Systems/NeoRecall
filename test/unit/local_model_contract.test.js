'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-local-contract-'));
test.after(() => fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }));

const { grammarSchema } = require('../../server/ai/providers/llama_provider');
const {
  consolidationJsonSchema, consolidationJsonSchemaFor, consolidationSchema,
  MEMORY_MAX_COUNT, MINI_MEMORY_MAX_COUNT, ENTITY_MAX_COUNT, SUMMARY_MAX_LENGTH,
} = require('../../server/ai/schemas/consolidation_schema');

function walk(node, visit) {
  if (Array.isArray(node)) { node.forEach((item) => walk(item, visit)); return; }
  if (!node || typeof node !== 'object') return;
  visit(node);
  Object.values(node).forEach((value) => walk(value, visit));
}

test('the grammar dialect keeps every union but spells it the way llama.cpp reads it', () => {
  const adapted = grammarSchema(consolidationJsonSchemaFor(['s1', 's2']));
  let unions = 0;
  walk(adapted, (node) => {
    assert.equal('anyOf' in node, false, 'anyOf has no grammar form; it must be rewritten as oneOf.');
    if ('oneOf' in node) unions += 1;
  });
  assert.ok(unions > 0, 'The contract has nullable unions; they must survive the rewrite.');
});

test('keywords a grammar cannot express are dropped, and only those', () => {
  const adapted = grammarSchema(consolidationJsonSchemaFor(['s1']));
  walk(adapted, (node) => {
    for (const dropped of ['pattern', 'minimum', 'maximum', 'maxLength', 'required']) {
      assert.equal(dropped in node, false, `${dropped} cannot be compiled into a grammar and must not survive.`);
    }
  });
  // The bounds that *can* be compiled are exactly the ones worth compiling: they
  // are what stops a small model from emitting an array that never ends.
  let bounded = 0;
  walk(adapted, (node) => { if ('maxItems' in node) bounded += 1; });
  assert.ok(bounded >= 4, 'Array bounds must reach the grammar, not just the response schema.');
  assert.ok(JSON.stringify(adapted).includes('"enum"'), 'Enumerated values must reach the grammar.');
});

test('one pass may only return a bounded answer', () => {
  // The response schema allows an unbounded array, so without these the grammar
  // does too — and a dense transcript then produces one mini-memory per
  // utterance until the token budget runs out, which arrives as truncation.
  const properties = consolidationJsonSchema.properties;
  assert.equal(properties.memories.maxItems, MEMORY_MAX_COUNT);
  assert.equal(properties.memories.items.properties.miniMemories.maxItems, MINI_MEMORY_MAX_COUNT);
  assert.equal(properties.entities.maxItems, ENTITY_MAX_COUNT);
  // Sections are deliberately uncapped: they have to partition the whole input,
  // so a cap could make valid coverage impossible.
  assert.equal('maxItems' in properties.conversationSections, false);
});

test('prose longer than its display bound is trimmed rather than rejected', () => {
  // A grammar can say "a string" but not "a string of at most two thousand
  // characters", so this is the one contract violation a locally constrained
  // model can still commit. Failing the whole consolidation over it would throw
  // away a correct answer and eventually quarantine the conversation.
  const parsed = consolidationSchema.parse({
    conversationSections: [{
      titleEn: 'Long summary', summaryEn: 'x'.repeat(SUMMARY_MAX_LENGTH + 500),
      memoryWorthy: false, topics: [], continuesPrevious: false, sourceSegmentIds: ['s1'],
    }],
    entities: [], memories: [], dailySummary: null,
  });
  const summary = parsed.conversationSections[0].summaryEn;
  assert.equal(summary.length, SUMMARY_MAX_LENGTH);
  assert.ok(summary.endsWith('…'), 'The trim stays visible instead of looking like the model stopped.');
});
