'use strict';

// One wearable recording, end to end: compressed AAC exactly as a watch or a
// Bluetooth pendant hands it over -> durable receipt -> transcript.
//
// The WAV path is covered by e2e_smoke. This exists because everything the
// phone records itself is PCM, so a decode or speech-detection failure that
// only affects the wearable container would classify real conversations as
// silence — and a chunk classified as silent has its audio deleted on both the
// server and the device that recorded it. There is no second chance to notice.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { assert, runScenario, wavDurationMs } = require('./lib/e2e_harness');

const fixture = path.resolve(process.env.NEORECALL_E2E_AUDIO || path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav'));
const sourceModels = path.resolve(process.env.NEORECALL_E2E_MODELS || path.join(os.homedir(), '.neorecall', 'models'));
const timeoutMs = Number(process.env.NEORECALL_E2E_TIMEOUT_MS || 10 * 60_000);

// The wearable containers actually seen in the field: raw ADTS from the watch
// recorder, and MPEG-4 from pendants that write files to flash.
const CONTAINERS = [
  { container: 'aac', codec: 'aac_lc', format: 'adts', extension: 'aac' },
  { container: 'mp4', codec: 'aac_lc', format: 'mp4', extension: 'm4a' },
];

function encode(format, extension) {
  const output = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-wearable-')), `wearable.${extension}`);
  execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', fixture,
    '-c:a', 'aac', '-b:a', '64k', '-ar', '16000', '-ac', '1', '-f', format, output]);
  return output;
}

async function main() {
  assert(fs.existsSync(fixture), `E2E audio fixture not found: ${fixture}`);
  const durationMs = wavDurationMs(fs.readFileSync(fixture));
  await runScenario('e2e-wearable', {
    sourceModels,
    timeoutMs,
    env: { NEORECALL_MIN_AI_AUDIO_MS: '0', NEORECALL_CONVERSATION_QUIET_CLOSE_MS: '1000' },
  }, async ({ baseUrl, api, poll, say }) => {
    const registration = await api('POST', '/api/v1/auth/register', null, {
      username: `e2e-wearable-${crypto.randomUUID().slice(0, 8)}`,
      password: `E2E-${crypto.randomBytes(18).toString('base64url')}`,
    });
    const token = registration.session.token;
    const deviceId = crypto.randomUUID();
    await api('POST', '/api/v1/devices', token, {
      id: deviceId, clientUuid: deviceId, name: 'E2E wearable', platform: 'android', kind: 'wearable',
    });

    for (const [index, { container, codec, format, extension }] of CONTAINERS.entries()) {
      say(`uploading ${durationMs} ms of speech as ${container}/${codec}`);
      const file = encode(format, extension);
      const bytes = fs.readFileSync(file);
      const sessionId = crypto.randomUUID();
      const sourceId = crypto.randomUUID();
      // Each container gets its own stretch of the clock. Two takes from one
      // device covering the same minutes are a genuine duplicate, and the
      // server is right to transcribe only one of them — that is a different
      // behaviour, covered by test/unit/same_device_coverage.test.js.
      const startedAt = new Date(Date.now() - (60 - index * 10) * 60_000).toISOString();
      await api('POST', '/api/v1/ingest/sessions', token, {
        id: sessionId, deviceId, clientUuid: sessionId, startedAt, timezone: 'UTC', consentAttestedAt: startedAt,
        sources: [{ id: sourceId, clientUuid: sourceId, kind: 'wearable', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }],
      });
      const form = new FormData();
      form.append('audio', new Blob([bytes], { type: 'audio/aac' }), `wearable.${extension}`);
      const upload = await fetch(`${baseUrl}/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/0`, {
        method: 'PUT',
        headers: {
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': crypto.randomUUID(),
          'X-Chunk-Sha256': crypto.createHash('sha256').update(bytes).digest('hex'),
          'X-Chunk-Duration-Ms': String(durationMs), 'X-Chunk-Overlap-Ms': '0', 'X-Channel-Layout': 'mono',
          'X-Monotonic-Offset-Ms': '0', 'X-Device-Started-At': startedAt,
          'X-Audio-Container': container, 'X-Audio-Codec': codec, 'X-Final-Chunk': 'true',
        },
        body: form,
      });
      if (!upload.ok) throw new Error(`Wearable ${container} upload failed: ${await upload.text()}`);
      const chunkId = (await upload.json()).receipt.chunkId;
      await api('PATCH', `/api/v1/ingest/sessions/${sessionId}`, token, {
        endedAt: new Date(Date.parse(startedAt) + durationMs).toISOString(), status: 'ended',
        sources: [{ id: sourceId, finalSequence: 0 }],
      });

      const terminal = await poll(`${container} terminal receipt`,
        () => api('POST', '/api/v1/ingest/chunks/status', token, { chunkIds: [chunkId] }),
        (value) => ['transcribed', 'silent'].includes(value.receipts?.[0]?.state));
      const receipt = terminal.receipts[0];
      // The whole point of the run. "silent" here is not a harmless
      // classification: it deletes the recording everywhere it exists.
      assert(receipt.state === 'transcribed',
        `Speech in a ${container}/${codec} recording was classified as silence, which deletes it.`);
      assert(receipt.transcriptSegmentCount > 0, `A transcribed ${container} recording carried no segments.`);
      const transcript = await api('GET', `/api/v1/recordings/${sessionId}/transcript`, token);
      assert(transcript.items?.length, `No transcript segments were persisted for ${container}.`);
      fs.rmSync(path.dirname(file), { recursive: true, force: true });
    }
  });
  console.log('NeoRecall wearable E2E passed: AAC (ADTS and MPEG-4) -> durable receipt -> transcript.');
}

main().catch((error) => {
  console.error(`[e2e-wearable] ${error.message}`);
  process.exit(1);
});
