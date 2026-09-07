'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { withInstructions, instructionText } = require('../../server/ai/prompts/custom_instructions');

const messages = Object.freeze([
  { role: 'system', content: 'task' },
  { role: 'user', content: 'evidence' },
]);

test('an account with no instructions sends exactly what the prompt built', () => {
  assert.equal(withInstructions(messages, {}, 'ask'), messages);
  assert.equal(withInstructions(messages, { instructionsMemories: 'Only for memories.' }, 'ask'), messages);
});

test('global and area instructions both apply, global first', () => {
  const text = instructionText({ instructionsGlobal: 'Always German.', instructionsAsk: 'Answer in two sentences.' }, 'ask');
  assert.equal(text, 'Always German.\n\nAnswer in two sentences.');
});

test('instructions land after the task and before the evidence', () => {
  const built = withInstructions(messages, { instructionsGlobal: 'Always German.' }, 'summaries');
  assert.deepEqual(built.map((message) => message.role), ['system', 'system', 'user']);
  assert.equal(built[0].content, 'task');
  assert.match(built[1].content, /Always German\./);
  // The output contract is not the user's to change, and the message says so.
  assert.match(built[1].content, /never change the required output format/);
  assert.equal(built[2].content, 'evidence');
});

test('whitespace-only instructions are no instructions', () => {
  assert.equal(withInstructions(messages, { instructionsGlobal: '   \n ' }, 'memories'), messages);
});
