'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { detect } = require('tinyld');

test('local statistical language detection distinguishes German and English', () => {
  assert.equal(detect('Wir besprechen heute den Projektplan und treffen uns danach in Berlin.'), 'de');
  assert.equal(detect('We will review the project report and meet again next week.'), 'en');
});

const { statisticalLanguage } = require('../../server/transcription/providers/sherpa_provider');

test('the statistical detector is not trusted with too little text', () => {
  // Measured against three hours of real council audio: every one of these was
  // labelled a language it plainly is not — Afrikaans, Turkish, Klingon — while
  // correctly labelled segments ran to a median of 88 characters.
  for (const fragment of ['Uh', 'So', 'Gentlemen.', 'We agree.', 'Councilor Holler.', 'At Worcester.']) {
    assert.equal(statisticalLanguage(fragment, 30), null, `"${fragment}" should have no language rather than a wrong one`);
  }
  assert.equal(statisticalLanguage('', 30), null);
});

test('enough text is still detected, and the threshold is what decides', () => {
  const english = 'We will review the project report and meet again next week.';
  const german = 'Wir besprechen heute den Projektplan und treffen uns danach in Berlin.';
  assert.equal(statisticalLanguage(english, 30), 'en');
  assert.equal(statisticalLanguage(german, 30), 'de');
  // A threshold of zero restores the previous unguarded behaviour exactly.
  assert.equal(statisticalLanguage('Gentlemen.', 0), detect('Gentlemen.'));
});
