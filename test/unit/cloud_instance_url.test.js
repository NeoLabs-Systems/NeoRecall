'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeInstanceUrl, sameOrigin } = require('../../server/services/cloud/instance_url');

test('https public hosts are accepted', () => {
  assert.equal(normalizeInstanceUrl('https://cloud.example.com/'), 'https://cloud.example.com');
  assert.equal(normalizeInstanceUrl('https://cloud.example.com/nextcloud/'), 'https://cloud.example.com/nextcloud');
});

test('http is allowed only for private or local hosts', () => {
  assert.equal(normalizeInstanceUrl('http://192.168.1.20'), 'http://192.168.1.20');
  assert.equal(normalizeInstanceUrl('http://localhost:8080'), 'http://localhost:8080');
  assert.throws(() => normalizeInstanceUrl('http://cloud.example.com'), /HTTPS/);
});

test('credentials, link-local hosts and junk are rejected', () => {
  assert.throws(() => normalizeInstanceUrl('https://user:pass@cloud.example.com'), /credentials/);
  assert.throws(() => normalizeInstanceUrl('https://169.254.169.254'), /cannot be used/);
  assert.throws(() => normalizeInstanceUrl('ftp://cloud.example.com'), /http or https/);
  assert.throws(() => normalizeInstanceUrl('not a url'), /not a valid URL/);
});

test('same-origin compares the instance and login endpoints', () => {
  assert.equal(sameOrigin('https://cloud.example.com', 'https://cloud.example.com/index.php/login/v2/poll'), true);
  assert.equal(sameOrigin('https://cloud.example.com', 'https://evil.example/login'), false);
});
