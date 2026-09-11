'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createLogger } = require('../../server/utils/logger');

function captureInfo(metadata) {
  const chunks = [];
  const original = process.stdout.write;
  process.stdout.write = (chunk, encoding, callback) => {
    chunks.push(Buffer.from(chunk).toString());
    if (typeof encoding === 'function') encoding();
    else if (typeof callback === 'function') callback();
    return true;
  };
  try {
    createLogger('logger-test').info('operational message', metadata);
  } finally {
    process.stdout.write = original;
  }
  return JSON.parse(chunks.join(''));
}

test('logger redacts identifiers and content fields without hiding the message', () => {
  const record = captureInfo({
    email: 'ada@example.test',
    ipAddress: '203.0.113.9',
    ip_address: '198.51.100.4',
    userAgent: 'NeoRecall/1.0',
    user_agent: 'Mozilla',
    note_text: 'private note',
    title_en: 'Private title',
    text: 'transcript line',
    body: 'request body',
    metadata: { leftover: true },
    token: 'nrs_secret',
  });
  assert.equal(record.message, 'operational message');
  assert.equal(record.scope, 'logger-test');
  assert.equal(record.email, '[redacted]');
  assert.equal(record.ipAddress, '[redacted]');
  assert.equal(record.ip_address, '[redacted]');
  assert.equal(record.userAgent, '[redacted]');
  assert.equal(record.user_agent, '[redacted]');
  assert.equal(record.note_text, '[redacted]');
  assert.equal(record.title_en, '[redacted]');
  assert.equal(record.text, '[redacted]');
  assert.equal(record.body, '[redacted]');
  assert.equal(record.metadata, '[redacted]');
  assert.equal(record.token, '[redacted]');
});
