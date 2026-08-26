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
  localAnalysis.analyze = () => analysis;
  global.fetch = async () => {
    providerCalls += 1;
    return new Response(JSON.stringify(TRANSCRIPT), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    return { segments: await host.transcribe({ filename: chunk, channelLayout: 'mono' }), providerCalls };
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
