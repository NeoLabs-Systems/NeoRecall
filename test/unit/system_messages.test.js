'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { appendSystem } = require('../../server/ai/prompts/system_messages');
const { withOutputLanguage } = require('../../server/ai/prompts/output_language');
const { withInstructions } = require('../../server/ai/prompts/custom_instructions');

// The failure this guards against is not subtle: a live Qwen3.5-4B answered
// every Ask with HTTP 500 and "System message must be at the beginning" as soon
// as a second system turn was added. One message, first, is the contract.
function assertSingleLeadingSystem(messages) {
  const systems = messages.filter((message) => message.role === 'system');
  assert.equal(systems.length, 1, 'exactly one system message');
  assert.equal(messages[0].role, 'system', 'the system message comes first');
}

test('appending to a list that already has a system message folds into it', () => {
  const messages = appendSystem(
    [{ role: 'system', content: 'task' }, { role: 'user', content: 'evidence' }],
    'extra',
  );
  assertSingleLeadingSystem(messages);
  assert.equal(messages[0].content, 'task\n\nextra');
  assert.equal(messages[1].content, 'evidence');
});

test('appending to a list with no system message creates one at the front', () => {
  const messages = appendSystem([{ role: 'user', content: 'evidence' }], 'extra');
  assertSingleLeadingSystem(messages);
  assert.equal(messages[0].content, 'extra');
});

test('empty content leaves the list exactly as it was', () => {
  const original = [{ role: 'system', content: 'task' }];
  assert.deepEqual(appendSystem(original, '   '), original);
  assert.deepEqual(appendSystem(original, null), original);
});

test('several leading system messages collapse into one', () => {
  const messages = appendSystem([
    { role: 'system', content: 'one' },
    { role: 'system', content: 'two' },
    { role: 'user', content: 'evidence' },
  ], 'three');
  assertSingleLeadingSystem(messages);
  assert.equal(messages[0].content, 'one\n\ntwo\n\nthree');
});

test('language and owner instructions together still leave one system message', () => {
  const base = [
    { role: 'system', content: 'TASK' },
    { role: 'user', content: 'EVIDENCE' },
  ];
  const messages = withInstructions(
    withOutputLanguage(base, 'de'),
    { instructionsGlobal: 'Answer in two sentences.' },
    'ask',
  );
  assertSingleLeadingSystem(messages);
  // The task speaks first, the language next, the owner's preference last, so
  // an instruction that says something more specific about language wins.
  const content = messages[0].content;
  assert.ok(content.indexOf('TASK') < content.indexOf('German'));
  assert.ok(content.indexOf('German') < content.indexOf('Answer in two sentences.'));
  assert.equal(messages[1].content, 'EVIDENCE');
});

test('neither layer disturbs a list when the account set nothing', () => {
  const base = [
    { role: 'system', content: 'TASK' },
    { role: 'user', content: 'EVIDENCE' },
  ];
  const messages = withInstructions(withOutputLanguage(base, null), {}, 'ask');
  assertSingleLeadingSystem(messages);
  assert.equal(messages.length, 2);
});
