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

test('the directive is inserted after the task system messages and before the evidence', () => {
  const messages = withOutputLanguage([
    { role: 'system', content: 'task' },
    { role: 'user', content: 'evidence' },
  ], 'de');
  assert.equal(messages.length, 3);
  assert.equal(messages[0].content, 'task');
  assert.equal(messages[1].role, 'system');
  assert.match(messages[1].content, /German \(Deutsch\)/);
  assert.equal(messages[2].content, 'evidence');
});

test('a message list with no user turn still receives the directive', () => {
  const messages = withOutputLanguage([{ role: 'system', content: 'task' }], 'en');
  assert.equal(messages.length, 2);
  assert.match(messages[1].content, /English/);
});
