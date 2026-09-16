'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-preprocess-'));

const { paths, ensureRuntimeDirs } = require('../../runtime/paths');
const preprocess = require('../../server/transcription/audio_preprocess');
const { decodeAudio } = require('../../server/transcription/audio_decode');
const { getConfig } = require('../../server/config');

ensureRuntimeDirs();
test.after(() => { fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const workDir = () => paths().audioWork;
const workFiles = () => fs.readdirSync(workDir()).filter((name) => !name.startsWith('.'));

// Quiet speech-shaped audio with a DC offset and a low rumble under it: the
// three things the chain exists to correct. Written as a real file because the
// module's whole job is to hand ffmpeg a path.
function fixture(name, { seconds = 4, channels = 1, amplitude = 0.02, rightSilent = false } = {}) {
  const rate = 16_000;
  const frames = rate * seconds;
  const output = Buffer.alloc(44 + frames * channels * 2);
  output.write('RIFF', 0); output.writeUInt32LE(output.length - 8, 4); output.write('WAVEfmt ', 8);
  output.writeUInt32LE(16, 16); output.writeUInt16LE(1, 20); output.writeUInt16LE(channels, 22);
  output.writeUInt32LE(rate, 24); output.writeUInt32LE(rate * channels * 2, 28);
  output.writeUInt16LE(channels * 2, 32); output.writeUInt16LE(16, 34);
  output.write('data', 36); output.writeUInt32LE(frames * channels * 2, 40);
  for (let frame = 0; frame < frames; frame += 1) {
    const t = frame / rate;
    const speech = Math.sin(2 * Math.PI * 220 * t) * amplitude;
    const rumble = Math.sin(2 * Math.PI * 30 * t) * amplitude * 0.5;
    const dc = 0.01;
    for (let channel = 0; channel < channels; channel += 1) {
      const value = channel === 1 && rightSilent ? 0 : speech + rumble + dc;
      output.writeInt16LE(Math.round(Math.max(-1, Math.min(1, value)) * 32767), 44 + (frame * channels + channel) * 2);
    }
  }
  const file = path.join(process.env.NEORECALL_HOME, name);
  fs.writeFileSync(file, output);
  return { file, durationMs: seconds * 1000 };
}

const peak = (samples) => { let highest = 0; for (const value of samples) highest = Math.max(highest, Math.abs(value)); return highest; };
const mean = (samples) => { let total = 0; for (const value of samples) total += value; return total / samples.length; };

test('conditioning does not move a single sample of the timeline', () => {
  // The load-bearing property of this whole feature. Diarization turns,
  // transcript timestamps and the speaker previews cut from the original chunk
  // all describe one timeline; a filter that dropped or added samples would
  // slide them apart with nothing anywhere to notice it.
  for (const [name, layout, channels] of [['mono.wav', 'mono', 1], ['stereo.wav', 'microphone_left_system_right', 2]]) {
    const { file, durationMs } = fixture(name, { channels });
    const before = decodeAudio(file, layout);
    const prepared = preprocess.prepare(file, { channelLayout: layout, durationMs });
    assert.equal(prepared.fellBack, false, `${layout} was conditioned`);
    const after = decodeAudio(prepared.filename, layout);
    assert.equal(after.length, before.length, `${layout} keeps its component count`);
    for (let index = 0; index < before.length; index += 1) {
      assert.equal(after[index].samples.length, before[index].samples.length, `${layout} keeps every sample`);
    }
    prepared.cleanup();
  }
});

test('a two-channel capture keeps which side is which', () => {
  // The microphone and the system channel are not interchangeable: speaker
  // identity is resolved per component. A downmix or a swap here would attribute
  // one person's speech to the other's stream.
  const { file, durationMs } = fixture('roles.wav', { channels: 2, rightSilent: true });
  const prepared = preprocess.prepare(file, { channelLayout: 'microphone_left_system_right', durationMs });
  const after = decodeAudio(prepared.filename, 'microphone_left_system_right');
  assert.deepEqual(after.map((component) => component.name), ['microphone', 'system']);
  assert.ok(peak(after[0].samples) > 0.01, 'the microphone side still carries the recording');
  assert.equal(peak(after[1].samples), 0, 'the silent system side was not filled in from the other channel');
  prepared.cleanup();
});

test('quiet audio is lifted, offset is removed, and nothing clips', () => {
  const { file, durationMs } = fixture('quiet.wav', { amplitude: 0.02 });
  const before = decodeAudio(file, 'mono')[0].samples;
  const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs });
  const after = decodeAudio(prepared.filename, 'mono')[0].samples;
  assert.ok(peak(after) > peak(before), 'a quiet recording is raised towards a level the service can read');
  assert.ok(peak(after) <= 0.99, 'and never into clipping');
  assert.ok(Math.abs(mean(after)) < Math.abs(mean(before)), 'the capture device\'s DC offset is gone');
  assert.deepEqual(prepared.applied, ['highpass', 'denoise', 'normalize', 'limiter']);
  prepared.cleanup();
});

test('the derived file lives apart from uploaded audio and is always removed', () => {
  // Not in audioTmp: the sweep there deletes anything unreferenced after a
  // minute, which would pull the file out from under an upload that may run for
  // the whole transcription timeout.
  const { file, durationMs } = fixture('lifecycle.wav');
  const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs });
  assert.equal(path.dirname(prepared.filename), workDir());
  assert.ok(fs.existsSync(prepared.filename));
  prepared.cleanup();
  assert.equal(fs.existsSync(prepared.filename), false);
  prepared.cleanup();
  assert.deepEqual(workFiles(), [], 'cleanup is safe to call twice and leaves nothing behind');
});

test('audio ffmpeg cannot read is passed through untouched rather than failing the chunk', () => {
  // The worst this module may ever do is nothing. A chunk that cannot be
  // conditioned still has to reach the transcription service.
  const file = path.join(process.env.NEORECALL_HOME, 'not-audio.wav');
  fs.writeFileSync(file, Buffer.from('audio'));
  const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs: 4_000 });
  assert.equal(prepared.filename, file);
  assert.equal(prepared.fellBack, true);
  assert.deepEqual(prepared.applied, []);
  assert.deepEqual(workFiles(), [], 'a failed attempt leaves no partial file behind');
});

test('a truncated result is refused instead of silently losing the end of a recording', () => {
  // Claimed forty seconds, holds one. Transcribing that would drop the rest of
  // the recording and look entirely successful doing it.
  const { file } = fixture('short.wav', { seconds: 1 });
  const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs: 40_000 });
  assert.equal(prepared.filename, file);
  assert.equal(prepared.fellBack, true);
  assert.deepEqual(workFiles(), []);
});

test('conditioning that runs long is abandoned in favour of the original', () => {
  // Ten minutes of audio through loudnorm, which upsamples internally for
  // true-peak measurement and is by far the most expensive mode. That takes
  // several seconds against a one-second deadline, so the test is about the
  // deadline being honoured rather than about how fast this machine is.
  const file = path.join(process.env.NEORECALL_HOME, 'slow.wav');
  const durationMs = 600_000;
  const generated = spawnSync(ffmpegPath, ['-v', 'error', '-y', '-f', 'lavfi',
    '-i', `sine=f=220:d=${durationMs / 1000}:r=16000`, '-c:a', 'pcm_s16le', file], { encoding: 'utf8' });
  assert.equal(generated.status, 0, generated.stderr);
  process.env.NEORECALL_AUDIO_PREPROCESS_NORMALIZER = 'loudnorm';
  process.env.NEORECALL_AUDIO_PREPROCESS_TIMEOUT_MS = '1000';
  try {
    const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs });
    assert.equal(prepared.filename, file);
    assert.equal(prepared.fellBack, true);
    assert.deepEqual(workFiles(), []);
  } finally {
    delete process.env.NEORECALL_AUDIO_PREPROCESS_NORMALIZER;
    delete process.env.NEORECALL_AUDIO_PREPROCESS_TIMEOUT_MS;
  }
});

test('an unusually long recording is transcribed rather than held in ffmpeg', () => {
  const { file } = fixture('bounded.wav');
  process.env.NEORECALL_AUDIO_PREPROCESS_MAX_DURATION_MS = '1000';
  try {
    const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs: 4_000 });
    assert.equal(prepared.filename, file);
    assert.equal(prepared.fellBack, false, 'declining to condition is not a failure');
  } finally { delete process.env.NEORECALL_AUDIO_PREPROCESS_MAX_DURATION_MS; }
});

test('with nothing to apply the original file is used, not re-encoded for nothing', () => {
  const { file, durationMs } = fixture('untouched.wav');
  const off = {
    NEORECALL_AUDIO_PREPROCESS_HIGHPASS_HZ: '0',
    NEORECALL_AUDIO_PREPROCESS_DENOISE_ENABLED: 'false',
    NEORECALL_AUDIO_PREPROCESS_NORMALIZER: 'off',
    NEORECALL_AUDIO_PREPROCESS_LIMITER_ENABLED: 'false',
  };
  Object.assign(process.env, off);
  try {
    assert.equal(preprocess.available(), false);
    assert.equal(preprocess.prepare(file, { channelLayout: 'mono', durationMs }).filename, file);
  } finally { for (const key of Object.keys(off)) delete process.env[key]; }

  process.env.NEORECALL_AUDIO_PREPROCESS_ENABLED = 'false';
  try {
    assert.equal(preprocess.available(), false);
    assert.equal(preprocess.prepare(file, { channelLayout: 'mono', durationMs }).filename, file);
  } finally { delete process.env.NEORECALL_AUDIO_PREPROCESS_ENABLED; }
  assert.deepEqual(workFiles(), []);
});

test('every filter the chain can compose keeps its channels and its samples', () => {
  // The guarantee the timeline rests on has to hold for the optional modes too,
  // not only the default chain, or turning a knob quietly breaks diarization.
  const { file, durationMs } = fixture('modes.wav', { channels: 2 });
  const expected = decodeAudio(file, 'stereo');
  for (const normalizer of ['dynaudnorm', 'loudnorm', 'speechnorm']) {
    process.env.NEORECALL_AUDIO_PREPROCESS_NORMALIZER = normalizer;
    try {
      const prepared = preprocess.prepare(file, { channelLayout: 'stereo', durationMs });
      assert.equal(prepared.fellBack, false, `${normalizer} ran`);
      const after = decodeAudio(prepared.filename, 'stereo');
      assert.equal(after.length, 2, `${normalizer} keeps both channels`);
      assert.equal(after[0].samples.length, expected[0].samples.length, `${normalizer} is sample-exact`);
      assert.ok(peak(after[0].samples) <= 0.99, `${normalizer} does not clip`);
      prepared.cleanup();
    } finally { delete process.env.NEORECALL_AUDIO_PREPROCESS_NORMALIZER; }
  }
});

test('the filter chain is composed with the arguments that make it safe', () => {
  const config = getConfig();
  const { applied, chain } = preprocess.buildFilters(config);
  assert.deepEqual(applied, ['highpass', 'denoise', 'normalize', 'limiter']);
  const text = chain.join(',');
  // alimiter's auto-level defaults to true and would raise everything back to
  // full scale, undoing the ceiling this stage exists to impose.
  assert.match(text, /alimiter=[^,]*level=false/);
  // Without the lookahead compensation the limiter shifts the whole timeline.
  assert.match(text, /alimiter=[^,]*latency=true/);
  // Channel coupling: without it each channel is levelled on its own and the
  // microphone/system relationship a two-channel capture depends on is lost.
  assert.match(text, /dynaudnorm=[^,]*:n=1/);
  assert.match(preprocess.NORMALIZERS.speechnorm(config).spec, /:l=1/);
  // Nothing that changes how many samples come out may ever appear here.
  assert.doesNotMatch(text, /silenceremove|atrim|atempo|agate|aresample=async/);
});

test('a stage this ffmpeg build lacks is skipped, not turned into a failed chunk', () => {
  const { applied } = preprocess.buildFilters(getConfig(), new Set(['highpass', 'alimiter']));
  assert.deepEqual(applied, ['highpass', 'limiter']);
});

test('the conditioned recording is what a transcription service would accept', () => {
  // The extension carries the content type on the multipart upload, so the
  // output has to actually be the format its name claims.
  const { file, durationMs } = fixture('format.wav');
  const prepared = preprocess.prepare(file, { channelLayout: 'mono', durationMs });
  assert.equal(path.extname(prepared.filename), '.wav');
  const probe = spawnSync(ffmpegPath, ['-v', 'error', '-i', prepared.filename, '-f', 'null', '-'], { encoding: 'utf8' });
  assert.equal(probe.status, 0, probe.stderr);
  prepared.cleanup();
});
