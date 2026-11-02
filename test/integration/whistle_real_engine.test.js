'use strict';

// Runs the whole Whistle path against the real engine: decode, windowing, the
// native library, word grouping. It needs the engine, the model and a Python
// interpreter, which a plain checkout does not have, so it runs only when they are
// named:
//
//   NEORECALL_TEST_WHISTLE_PYTHON=/path/to/python3
//   NEORECALL_TEST_WHISTLE_LIBRARY=/path/to/libneedle.dylib
//   NEORECALL_TEST_WHISTLE_WEIGHTS=/path/to/whistle.cact
//
// (An installed NeoRecall has all three under ~/.neorecall/models/local/whistle.)

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const python = process.env.NEORECALL_TEST_WHISTLE_PYTHON;
const library = process.env.NEORECALL_TEST_WHISTLE_LIBRARY;
const weights = process.env.NEORECALL_TEST_WHISTLE_WEIGHTS;
const skip = python && library && weights ? false : 'the Whistle engine, model and Python are not named in the environment';

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-whistle-real-'));
process.env.TRANSCRIPTION_PROVIDER = 'whistle-local';

const { migrate } = require('../../server/db/migrate');
const { closeDatabase } = require('../../server/db/database');
const { getConfig } = require('../../server/config');
const { WhistleRuntime } = require('../../server/transcription/local_asr/runtime');
const { WhistleProvider } = require('../../server/transcription/providers/whistle_provider');

const sample = path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav');
let runtime;
let provider;

test.before(async () => {
  if (skip) return;
  migrate();
  runtime = new WhistleRuntime({
    files: { python, library, weights, worker: path.join(__dirname, '..', '..', 'server', 'transcription', 'local_asr', 'whistle_worker.py') },
    config: getConfig(),
  });
  runtime.ensureStarted();
  await runtime.whenSettled();
  provider = new WhistleProvider({ asr: {
    getInstaller: () => ({ supported: true, languages: () => ['en', 'de', 'fr', 'es', 'it', 'nl', 'pl'] }),
    getRuntime: () => runtime,
    reset: async () => {},
  } });
});

test.after(async () => {
  await runtime?.stop();
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('reads real speech with usable timestamps', { skip }, async () => {
  const segments = await provider.fetchSegments({ filename: sample });
  const text = segments.map((segment) => segment.text).join(' ');
  assert.match(text, /Berlin/);
  assert.match(text, /release notes/i);
  assert.ok(segments.length >= 3, 'the speech is split into utterance-sized segments');
  for (const segment of segments) assert.ok(segment.endMs >= segment.startMs && segment.endMs <= 19_000);
  for (let index = 1; index < segments.length; index += 1) assert.ok(segments[index].startMs >= segments[index - 1].startMs);
});

test('a chunk longer than the model limit is windowed and stays on one timeline', { skip }, async () => {
  const long = path.join(process.env.NEORECALL_HOME, 'long.wav');
  const list = path.join(process.env.NEORECALL_HOME, 'list.txt');
  fs.writeFileSync(list, [sample, sample, sample].map((file) => `file '${file}'`).join('\n'));
  const joined = spawnSync(require('ffmpeg-static'), ['-v', 'error', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', long]);
  assert.equal(joined.status, 0, String(joined.stderr));
  const segments = await provider.fetchSegments({ filename: long });
  const berlin = segments.filter((segment) => /Berlin/.test(segment.text));
  assert.ok(berlin.length >= 2, `expected the repeated sentence in most windows, found ${berlin.length}`);
  assert.ok(segments.at(-1).endMs > 45_000 && segments.at(-1).endMs <= 56_000, `ends at ${segments.at(-1).endMs}`);
  for (let index = 1; index < segments.length; index += 1) assert.ok(segments[index].startMs >= segments[index - 1].startMs - 50);
});

test('silence yields no segments', { skip }, async () => {
  const segments = await provider.fetchSegments({ filename: path.join(__dirname, '..', 'fixtures', 'silence.wav') });
  assert.deepEqual(segments, []);
});
