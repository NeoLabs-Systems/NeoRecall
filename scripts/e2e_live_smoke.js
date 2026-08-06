'use strict';

// A recording that is still running, end to end, against the real speech models.
//
// This is the case an always-on device actually lives in: chunks arrive while
// the session stays open, and the user must be able to look into the
// conversation before it ends. It asserts the three properties the live path
// exists for — the transcript grows as chunks land, the still-open conversation
// carries a readable provisional insight, and its identity survives the boundary
// reruns that happen on every new chunk — and then that closing it yields
// exactly one memory rather than one per chunk.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { assert, runScenario, sliceWav } = require('./lib/e2e_harness');

const fixture = path.resolve(process.env.NEORECALL_E2E_AUDIO || path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav'));
const sourceModels = path.resolve(process.env.NEORECALL_E2E_MODELS || path.join(os.homedir(), '.neorecall', 'models'));
const timeoutMs = Number(process.env.NEORECALL_E2E_TIMEOUT_MS || 10 * 60_000);
const SLICES = 3;

async function uploadChunk({ baseUrl, token, sessionId, sourceId }, sequence, slice, offsetMs, startedAt, isFinal) {
  const digest = crypto.createHash('sha256').update(slice.bytes).digest('hex');
  const form = new FormData();
  form.append('audio', new Blob([slice.bytes], { type: 'audio/wav' }), `live-${sequence}.wav`);
  const response = await fetch(`${baseUrl}/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/${sequence}`, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`, 'Idempotency-Key': crypto.randomUUID(), 'X-Chunk-Sha256': digest,
      'X-Chunk-Duration-Ms': String(slice.durationMs), 'X-Chunk-Overlap-Ms': '0', 'X-Channel-Layout': 'mono',
      'X-Monotonic-Offset-Ms': String(offsetMs),
      'X-Device-Started-At': new Date(Date.parse(startedAt) + offsetMs).toISOString(),
      'X-Audio-Container': 'wav', 'X-Audio-Codec': 'pcm_s16le', ...(isFinal ? { 'X-Final-Chunk': 'true' } : {}),
    },
    body: form,
  });
  if (!response.ok) throw new Error(`Live chunk ${sequence} upload failed: ${await response.text()}`);
  return (await response.json()).receipt.chunkId;
}

async function main() {
  assert(fs.existsSync(fixture), `E2E audio fixture not found: ${fixture}`);
  const slices = sliceWav(fs.readFileSync(fixture), SLICES);
  await runScenario('e2e-live', {
    sourceModels,
    timeoutMs,
    env: {
      // The fixture is eighteen seconds of speech, so the thresholds that bound
      // a real day of recording have to be scaled to it. Everything else — the
      // pipeline, the models, the ordering guarantees — is untouched.
      NEORECALL_CHUNK_MIN_MS: '1000',
      NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS: '20',
      NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS: '10',
      NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS: '0',
      // Pinned rather than inherited: the fixture is eighteen seconds of
      // speech, and the audio floor an operator may raise must not decide
      // whether this run reaches a model.
      NEORECALL_MIN_AI_AUDIO_MS: '0',
      NEORECALL_MIN_NEW_MATERIAL_CHARS: '1',
      NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS: '0',
      // Long enough that the recording is still live while the chunks upload,
      // short enough that the run does not have to wait five real minutes for
      // the conversation to settle.
      NEORECALL_CONVERSATION_QUIET_CLOSE_MS: '15000',
      NEORECALL_SCHEDULER_INTERVAL_MS: '2000',
    },
  }, async ({ baseUrl, api, poll, mock, say }) => {
    say('registering the isolated E2E user and recorder');
    const registration = await api('POST', '/api/v1/auth/register', null, {
      username: `live-${crypto.randomUUID().slice(0, 8)}`,
      password: `E2E-${crypto.randomBytes(18).toString('base64url')}`,
    });
    const token = registration.session.token;
    const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
    // The recording starts now, so its audio counts as current and the
    // conversation stays open while chunks arrive — exactly as it would on a
    // device that is recording at this moment.
    const startedAt = new Date().toISOString();
    await api('POST', '/api/v1/devices', token, { id: deviceId, clientUuid: deviceId, name: 'Live recorder', platform: process.platform, kind: 'desktop' });
    await api('POST', '/api/v1/ingest/sessions', token, {
      id: sessionId, deviceId, clientUuid: sessionId, startedAt, timezone: 'UTC', consentAttestedAt: startedAt,
      sources: [{ id: sourceId, clientUuid: sourceId, kind: 'microphone', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }],
    });
    const upload = { baseUrl, token, sessionId, sourceId };

    say('uploading the first chunks while the session stays open');
    let offsetMs = 0;
    const chunkIds = [];
    for (let sequence = 0; sequence < SLICES - 1; sequence += 1) {
      chunkIds.push(await uploadChunk(upload, sequence, slices[sequence], offsetMs, startedAt, false));
      offsetMs += slices[sequence].durationMs;
    }
    const transcribed = await poll('incremental transcripts',
      () => api('POST', '/api/v1/ingest/chunks/status', token, { chunkIds }),
      (value) => value.receipts?.length === chunkIds.length && value.receipts.every((item) => ['transcribed', 'silent'].includes(item.state)));
    assert(transcribed.receipts.every((item) => item.serverAudioDeletedAt),
      'A chunk reached a terminal state without proof its server audio was deleted.');
    const partial = await api('GET', `/api/v1/recordings/${sessionId}/transcript`, token);
    assert(partial.items?.length, 'No transcript was available while the recording was still running.');

    say('waiting for the live insight on the conversation that is still recording');
    const live = await poll('provisional insight',
      () => api('GET', '/api/v1/conversations?state=open', token),
      (value) => value.items?.[0]?.insight_state === 'provisional');
    const conversation = live.items[0];
    assert(conversation.title_en && conversation.summary_en, 'A provisional insight carried no title or summary.');
    assert(conversation.memory_worthy !== undefined, 'A provisional insight did not report memory worthiness.');

    const previews = mock.of('preview');
    assert(previews.length >= 1, 'No conversation preview request was made.');
    const previewed = previews[0].input.conversation.segments.map((segment) => segment.text).join(' ');
    assert(previewed.trim().length > 0, 'The preview request carried no transcribed speech.');
    assert(previews[0].input.conversation.segments.every((segment) => segment.id === undefined),
      'The preview request carried evidence identifiers it cannot cite.');
    assert(mock.count('consolidation') === 0, 'A memory was consolidated while the conversation was still recording.');

    say('uploading the final chunk and confirming the conversation kept its identity');
    await uploadChunk(upload, SLICES - 1, slices[SLICES - 1], offsetMs, startedAt, true);
    offsetMs += slices[SLICES - 1].durationMs;
    await poll('final chunk transcript',
      () => api('GET', `/api/v1/recordings/${sessionId}/transcript`, token),
      (value) => value.items.length > partial.items.length);
    const stillOpen = await api('GET', '/api/v1/conversations?state=open', token);
    assert(stillOpen.items.length === 1 && stillOpen.items[0].id === conversation.id,
      'The open conversation changed identity when new speech arrived, discarding its live insight.');
    assert(stillOpen.items[0].title_en, 'The live insight was lost when the conversation was extended.');

    say('ending the recording and consolidating one memory for it');
    await api('PATCH', `/api/v1/ingest/sessions/${sessionId}`, token, {
      endedAt: new Date(Date.parse(startedAt) + offsetMs).toISOString(), status: 'ended', sources: [{ id: sourceId, finalSequence: SLICES - 1 }],
    });
    // A conversation closes because the speech went quiet, not because a session
    // was ended, so this waits the quiet window out rather than forcing it.
    await poll('conversation settling after the recording ended',
      () => api('GET', '/api/v1/conversations', token),
      (value) => value.items?.length && value.items.every((item) => item.state !== 'open'));

    await poll('memory consolidation',
      () => api('GET', '/api/v1/memories/consolidations/latest', token),
      (value) => value.run?.state === 'succeeded');
    const memories = await api('GET', '/api/v1/memories', token);
    assert(memories.items?.length === 1, `One continuous recording produced ${memories.items?.length} memories instead of one.`);
    const consolidated = await api('GET', '/api/v1/conversations?state=consolidated', token);
    assert(consolidated.items?.length === 1, 'The continuous recording did not resolve to a single consolidated conversation.');
    assert(consolidated.items[0].id === conversation.id, 'The consolidated conversation is not the one the user was watching.');
    assert(consolidated.items[0].insight_state === 'final', 'The provisional insight was not replaced by a final one.');
    process.stdout.write('NeoRecall live E2E passed: open recording -> incremental transcript -> live insight -> one final memory.\n');
  });
}

main().catch((error) => { process.stderr.write(`${error.stack || error.message}\n`); process.exitCode = 1; });
