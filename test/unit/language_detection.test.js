'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { detect } = require('tinyld');

test('local statistical language detection distinguishes German and English', () => {
  assert.equal(detect('Wir besprechen heute den Projektplan und treffen uns danach in Berlin.'), 'de');
  assert.equal(detect('We will review the project report and meet again next week.'), 'en');
});
