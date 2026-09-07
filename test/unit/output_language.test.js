'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { resolveLanguage, withOutputLanguage, LANGUAGE_CODES } = require('../../server/ai/prompts/output_language');

test('an unknown or missing language code resolves to the default rather than throwing', () => {
  assert.equal(resolveLanguage('de').name, 'German');
  assert.equal(resolveLanguage('DE').name, 'German');
  assert.equal(resolveLanguage(null).code, 'en');
  assert.equal(resolveLanguage('klingon').code, 'en');
  assert.deepEqual(LANGUAGE_CODES, ['en', 'de']);
});

test('the directive is folded into the task system message, ahead of the evidence', () => {
  const messages = withOutputLanguage([
    { role: 'system', content: 'task' },
    { role: 'user', content: 'evidence' },
  ], 'de');
  // One system message, first: some chat templates reject anything else.
  assert.equal(messages.length, 2);
  assert.equal(messages.filter((message) => message.role === 'system').length, 1);
  assert.match(messages[0].content, /^task\n\n/);
  assert.match(messages[0].content, /German \(Deutsch\)/);
  assert.equal(messages[1].content, 'evidence');
});

test('a message list with no user turn still receives the directive', () => {
  const messages = withOutputLanguage([{ role: 'system', content: 'task' }], 'en');
  assert.equal(messages.length, 1);
  assert.match(messages[0].content, /English/);
});
