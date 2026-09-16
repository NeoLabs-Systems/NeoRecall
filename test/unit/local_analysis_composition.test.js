'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-analysis-'));
// A real custom OpenAI-compatible endpoint, so the composition is exercised
// through the actual provider rather than around it. Only the network is faked.
process.env.TRANSCRIPTION_PROVIDER = 'openai-compatible';
process.env.TRANSCRIPTION_API_BASE_URL = 'http://speech.internal/v1';
process.env.TRANSCRIPTION_API_MODEL = 'test-asr';

const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { alignSegments } = require('../../server/transcription/speaker_alignment');
const localAnalysis = require('../../server/transcription/local_analysis');
const host = require('../../server/workers/inference_host');
const { paths, ensureRuntimeDirs } = require('../../runtime/paths');

ensureRuntimeDirs();
const derivedAudio = () => fs.readdirSync(paths().audioWork).filter((name) => !name.startsWith('.'));

const chunk = path.join(process.env.NEORECALL_HOME, 'chunk.wav');
fs.writeFileSync(chunk, Buffer.from('audio'));

const TRANSCRIPT = {
  language: 'de',
  segments: [
    { start: 0, end: 2, text: 'Guten Morgen.' },
    { start: 5, end: 7, text: 'I am well.' },
  ],
};

/// Runs the inference host with the local pass replaced and the network faked,
/// so what is under test is how the two halves are joined.
async function transcribeWith(analysis) {
  const originalAnalyze = localAnalysis.analyze;
  const originalFetch = global.fetch;
  let providerCalls = 0;
  const analyzed = [];
  localAnalysis.analyze = (filename) => { analyzed.push(filename); return analysis; };
  global.fetch = async () => {
    providerCalls += 1;
    return new Response(JSON.stringify(TRANSCRIPT), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    const preprocessing = [];
    const segments = await host.transcribe(
      { filename: chunk, channelLayout: 'mono', durationMs: 8_000 },
      (report) => preprocessing.push(report),
    );
    return { segments, providerCalls, analyzed, preprocessing };
  } finally {
    localAnalysis.analyze = originalAnalyze;
    global.fetch = originalFetch;
  }
}

test('silence never reaches the transcription service', async () => {
  // The whole reason speech detection stayed local. A recorder left running all
  // day is mostly silence, and paying an external service to transcribe an empty
  // room is the one cost that is entirely avoidable.
  const result = await transcribeWith({ analyzed: true, hasSpeech: false, turns: [] });
  assert.equal(result.providerCalls, 0, 'A silent chunk must not be sent anywhere.');
  assert.deepEqual(result.segments, []);
});

test('a transcript is joined to the voice it overlaps most', async () => {
  const embeddingA = new Float32Array([1, 0, 0]);
  const embeddingB = new Float32Array([0, 1, 0]);
  const result = await transcribeWith({ analyzed: true, hasSpeech: true, turns: [
    { startMs: 0, endMs: 2_500, speaker: 0, embedding: embeddingA },
    { startMs: 4_500, endMs: 7_500, speaker: 1, embedding: embeddingB },
  ] });
  assert.equal(result.providerCalls, 1, 'Speech is transcribed once, as a whole file.');
  assert.deepEqual(result.segments.map((segment) => segment.diarizationSpeaker), [0, 1]);
  // The embedding is the point: a service can label speakers inside one request,
  // but only a voice fingerprint identifies the same person in another one.
  assert.deepEqual(result.segments[0].speakerEmbedding, embeddingA);
  assert.deepEqual(result.segments[1].speakerEmbedding, embeddingB);
  assert.equal(result.segments[0].text, 'Guten Morgen.', 'The words still come from the service.');
});

test('without the local models the transcript still arrives, just anonymous', async () => {
  // The native runtime has no build for every platform and the models can be
  // skipped. Neither may cost the user their transcript.
  const result = await transcribeWith({ analyzed: false, hasSpeech: true, turns: [] });
  assert.equal(result.providerCalls, 1);
  assert.deepEqual(result.segments.map((segment) => segment.text), ['Guten Morgen.', 'I am well.']);
  assert.equal(result.segments[0].diarizationSpeaker, null, 'No voice was identified, and none is claimed.');
});

test('audio that cannot be conditioned is still transcribed from the original', async () => {
  // This chunk is not audio at all, so conditioning fails on every run above and
  // below. That is the point: the pipeline's behaviour when the filter chain
  // cannot run has to be exactly the behaviour it had before the chain existed.
  const result = await transcribeWith({ analyzed: false, hasSpeech: true, turns: [] });
  assert.equal(result.providerCalls, 1, 'a failed conditioning attempt must not cost the user their transcript');
  assert.deepEqual(result.segments.map((segment) => segment.text), ['Guten Morgen.', 'I am well.']);
  assert.equal(result.preprocessing[0].fellBack, true, 'and the fallback is reported rather than hidden');
  assert.deepEqual(result.analyzed, [chunk], 'the pass that could not be conditioned reads the original file');
});

test('no derived audio survives a request, including one that was never transcribed', async () => {
  // Conditioned copies are the one kind of audio this server creates itself.
  // They may not outlive the request that needed them, on any path.
  await transcribeWith({ analyzed: true, hasSpeech: false, turns: [] });
  assert.deepEqual(derivedAudio(), [], 'a silent chunk leaves nothing behind');
  await transcribeWith({ analyzed: true, hasSpeech: true, turns: [] });
  assert.deepEqual(derivedAudio(), [], 'a transcribed chunk leaves nothing behind');
});

test('speaker detection reads the original recording, transcription reads the conditioned one', async () => {
  // Handing the two passes different files is only safe because conditioning is
  // sample-exact, and only correct because the local models measurably do worse
  // on conditioned audio than on the recording as it arrived. Both halves of
  // that are asserted here.
  const real = path.join(process.env.NEORECALL_HOME, 'real.wav');
  fs.copyFileSync(path.join(__dirname, '../fixtures/de_en_two_speakers.wav'), real);

  const run = async () => {
    const originalAnalyze = localAnalysis.analyze;
    const originalFetch = global.fetch;
    const analyzed = [];
    let sentBytes = 0;
    localAnalysis.analyze = (filename) => { analyzed.push(filename); return { analyzed: false, hasSpeech: true, turns: [] }; };
    global.fetch = async (_url, options) => {
      sentBytes = options.body.get('file').size;
      return new Response(JSON.stringify(TRANSCRIPT), { status: 200, headers: { 'Content-Type': 'application/json' } });
    };
    try {
      await host.transcribe({ filename: real, channelLayout: 'mono', durationMs: 17_980 });
    } finally {
      localAnalysis.analyze = originalAnalyze;
      global.fetch = originalFetch;
    }
    return { analyzed, sentBytes };
  };

  const byDefault = await run();
  assert.equal(byDefault.analyzed[0], real, 'speaker detection is given the recording as it arrived');
  assert.ok(byDefault.sentBytes > 0, 'and the transcription service was still sent audio');
  assert.deepEqual(derivedAudio(), [], 'the conditioned copy is gone once the request is over');

  process.env.NEORECALL_AUDIO_PREPROCESS_TARGET = 'stt+analysis';
  try {
    const opted = await run();
    assert.notEqual(opted.analyzed[0], real, 'opting in hands speaker detection the conditioned copy instead');
    assert.equal(path.dirname(opted.analyzed[0]), paths().audioWork);
  } finally { delete process.env.NEORECALL_AUDIO_PREPROCESS_TARGET; }
  assert.deepEqual(derivedAudio(), []);
});

test('overlapping speech is marked rather than silently attributed to one voice', () => {
  const aligned = alignSegments(
    [{ text: 'Both at once.', startMs: 0, endMs: 1_000 }],
    [{ startMs: 0, endMs: 900, speaker: 0, embedding: null }, { startMs: 100, endMs: 1_000, speaker: 1, embedding: null }],
  );
  assert.equal(aligned[0].diarizationSpeaker, 0, 'The larger overlap wins the attribution.');
  assert.equal(aligned[0].overlappingSpeech, true, 'That a second voice was talking over it is recorded.');
});

test('availability is a fact about the installation, not a preference', () => {
  // This home directory holds no models, so speaker identity is unavailable and
  // the setting that governs it has to say so rather than offer a choice.
  assert.equal(localAnalysis.available(), false);
  const crypto = require('node:crypto');
  const db = require('../../server/db/database').getDatabase();
  const userId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(userId, `u-${userId.slice(0, 8)}`, 'hash');
  assert.equal(require('../../server/services/settings/settings_service').get(userId).speakerIdentityAvailable, false);
});
