'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { readZipMember } = require('../../server/local_runtime/zip_member');
const { makeZip } = require('../helpers/archives');

const library = Buffer.from('native library bytes '.repeat(500));

test('reads a deflated member and a stored member', () => {
  for (const deflate of [true, false]) {
    const archive = makeZip({ 'pkg/__init__.py': Buffer.from('x'), 'pkg/libneedle3.so': library, 'pkg/other': Buffer.from('y') }, { deflate });
    assert.deepEqual(readZipMember(archive, 'pkg/libneedle3.so'), library);
  }
});

test('names the member when it is not there', () => {
  assert.throws(() => readZipMember(makeZip({ a: Buffer.from('1') }), 'missing'), { code: 'LOCAL_ARCHIVE_INVALID', message: /missing/ });
});

test('rejects bytes that are not a zip', () => {
  assert.throws(() => readZipMember(Buffer.from('not a zip at all, just text'), 'a'), { code: 'LOCAL_ARCHIVE_INVALID' });
});
