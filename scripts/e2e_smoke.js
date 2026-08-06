'use strict';

// One finished recording, end to end, against the real speech models:
// audio -> durable receipt -> transcript -> search -> memory -> cited Ask.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { assert, runScenario, wavDurationMs } = require('./lib/e2e_harness');

const fixture = path.resolve(process.env.NEORECALL_E2E_AUDIO || path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav'));
const sourceModels = path.resolve(process.env.NEORECALL_E2E_MODELS || path.join(os.homedir(), '.neorecall', 'models'));
const timeoutMs = Number(process.env.NEORECALL_E2E_TIMEOUT_MS || 10 * 60_000);

async function main() {
  assert(fs.existsSync(fixture), `E2E audio fixture not found: ${fixture}`);
  await runScenario('e2e', {
    sourceModels,
    timeoutMs,
    env: {
      // Pinned rather than inherited: the fixture is eighteen seconds of
      // speech, and the audio floor an operator may raise must not decide
      // whether this run reaches a model.
      NEORECALL_MIN_AI_AUDIO_MS: '0',
      NEORECALL_MIN_NEW_MATERIAL_CHARS: '1',
      NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS: '3600000',
      NEORECALL_CONVERSATION_QUIET_CLOSE_MS: '1000',
      // A finished-recording run must not race a live preview for the same
      // conversation, so the preview threshold is put out of reach of this
      // fixture; the live run covers that path.
      NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS: '200000',
    },
  }, async ({ baseUrl, api, poll, mock, say }) => {
    say('registering the isolated E2E user and recorder');
    const registration = await api('POST', '/api/v1/auth/register', null, {
      username: `e2e-${crypto.randomUUID().slice(0, 8)}`,
      password: `E2E-${crypto.randomBytes(18).toString('base64url')}`,
    });
    const token = registration.session.token;
    const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
    const startedAt = new Date(Date.now() - 10 * 60_000).toISOString();
    const bytes = fs.readFileSync(fixture);
    const duration = wavDurationMs(bytes);
    await api('POST', '/api/v1/devices', token, { id: deviceId, clientUuid: deviceId, name: 'E2E recorder', platform: process.platform, kind: 'desktop' });
    await api('POST', '/api/v1/ingest/sessions', token, {
      id: sessionId, deviceId, clientUuid: sessionId, startedAt, timezone: 'UTC', consentAttestedAt: startedAt,
      sources: [{ id: sourceId, clientUuid: sourceId, kind: 'microphone', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }],
    });
    const digest = crypto.createHash('sha256').update(bytes).digest('hex');
    const form = new FormData();
    form.append('audio', new Blob([bytes], { type: 'audio/wav' }), 'e2e.wav');
    const upload = await fetch(`${baseUrl}/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/0`, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${token}`, 'Idempotency-Key': crypto.randomUUID(), 'X-Chunk-Sha256': digest,
        'X-Chunk-Duration-Ms': String(duration), 'X-Chunk-Overlap-Ms': '0', 'X-Channel-Layout': 'mono',
        'X-Monotonic-Offset-Ms': '0', 'X-Device-Started-At': startedAt, 'X-Audio-Container': 'wav',
        'X-Audio-Codec': 'pcm_s16le', 'X-Final-Chunk': 'true',
      },
      body: form,
    });
    if (!upload.ok) throw new Error(`E2E upload failed: ${await upload.text()}`);
    const chunkId = (await upload.json()).receipt.chunkId;
    await api('PATCH', `/api/v1/ingest/sessions/${sessionId}`, token, {
      endedAt: new Date(Date.parse(startedAt) + duration).toISOString(), status: 'ended', sources: [{ id: sourceId, finalSequence: 0 }],
    });

    say('waiting for the crash-safe terminal transcript receipt');
    const terminal = await poll('terminal transcript receipt',
      () => api('POST', '/api/v1/ingest/chunks/status', token, { chunkIds: [chunkId] }),
      (value) => ['transcribed', 'silent'].includes(value.receipts?.[0]?.state));
    const receipt = terminal.receipts[0];
    assert(receipt.state === 'transcribed', 'Speech fixture was classified as silence.');
    assert(receipt.persistedAt && receipt.serverAudioDeletedAt && receipt.transcriptSha256, 'Terminal receipt lacks durable deletion proof.');
    const transcript = await api('GET', `/api/v1/recordings/${sessionId}/transcript`, token);
    assert(transcript.items?.length && transcript.items.some((item) => item.language), 'Original-language transcript segments were not persisted.');

    say('waiting for token-free boundaries and the hybrid search index');
    await poll('closed conversation', () => api('GET', '/api/v1/conversations?state=closed', token), (value) => value.items?.length > 0);
    const search = await poll('hybrid search index', () => api('GET', `/api/v1/search?q=${encodeURIComponent('project report')}`, token), (value) => value.results?.length > 0);
    assert(search.results.some((item) => item.kind === 'segment'), 'Search did not return transcript evidence.');

    say('running the single-call memory consolidation');
    const queued = await api('POST', '/api/v1/memories/consolidations', token, {});
    assert(queued.queued, 'Consolidation did not queue.');
    await poll('memory consolidation', () => api('GET', '/api/v1/memories/consolidations/latest', token), (value) => value.run?.state === 'succeeded');
    const memories = await api('GET', '/api/v1/memories', token);
    assert(memories.items?.[0]?.title_en === 'Project discussion', 'English memory was not persisted.');
    const refined = await api('GET', '/api/v1/conversations?state=consolidated', token);
    assert(refined.items?.[0]?.title_en === 'Project discussion' && refined.items?.[0]?.summary_en, 'Conversation refinement was not persisted.');
    assert(refined.items?.[0]?.insight_state === 'final', 'A consolidated conversation must carry a final insight.');
    const daily = await api('GET', '/api/v1/daily-summaries', token);
    assert(daily.items?.length, 'Incremental daily summary was not persisted.');

    say('running cited Ask over the local retrieval result');
    const answer = await api('POST', '/api/v1/search/ask', token, { question: 'What was discussed?' });
    assert(answer.answer && answer.citations.length, 'Ask did not return cited context.');

    say('verifying the durable consolidation budget gate');
    const calls = mock.count();
    let gated = false;
    try { await api('POST', '/api/v1/memories/consolidations', token, {}); } catch (error) { gated = error.status === 429; }
    assert(gated && mock.count() === calls, 'Second consolidation was not blocked before an outbound request.');
    process.stdout.write('NeoRecall E2E passed: audio -> durable receipt -> transcript -> search -> memory -> cited Ask.\n');
  });
}

main().catch((error) => { process.stderr.write(`${error.stack || error.message}\n`); process.exitCode = 1; });
