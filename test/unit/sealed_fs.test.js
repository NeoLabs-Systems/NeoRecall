'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-seal-'));

const sealedFs = require('../../server/utils/sealed_fs');

test.after(() => {
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('sealing a file hides plaintext and still round-trips', () => {
  const file = path.join(process.env.NEORECALL_HOME, 'clip.wav');
  const payload = Buffer.from('RIFF____WAVE secret-speech-bytes');
  fs.writeFileSync(file, payload);
  sealedFs.sealInPlace(file);
  assert.equal(sealedFs.isSealed(file), true);
  assert.ok(!fs.readFileSync(file).includes(Buffer.from('secret-speech-bytes')));
  assert.ok(sealedFs.readFileSync(file).equals(payload));
  sealedFs.sealInPlace(file);
  assert.ok(sealedFs.readFileSync(file).equals(payload), 'sealing twice does not double-encrypt');
});

test('legacy plaintext files still read', () => {
  const file = path.join(process.env.NEORECALL_HOME, 'plain.bin');
  fs.writeFileSync(file, 'still-plain');
  assert.equal(sealedFs.isSealed(file), false);
  assert.equal(sealedFs.readFileSync(file, 'utf8'), 'still-plain');
});
