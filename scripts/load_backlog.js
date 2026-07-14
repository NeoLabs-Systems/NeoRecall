'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const baseUrl = (process.env.NEORECALL_BASE_URL || 'http://127.0.0.1:4500').replace(/\/$/, '');
const fixture = path.resolve(process.env.NEORECALL_BACKLOG_AUDIO || path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav'));
const count = Number(process.env.NEORECALL_BACKLOG_CHUNKS || process.argv[2] || 2880);

function durationMs(bytes) {
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const size = bytes.readUInt32LE(offset + 4);
    if (bytes.toString('ascii', offset, offset + 4) === 'fmt ') var byteRate = bytes.readUInt32LE(offset + 16);
    if (bytes.toString('ascii', offset, offset + 4) === 'data') return Math.round(size / byteRate * 1000);
    offset += 8 + size + (size % 2);
  }
  throw new Error('Backlog fixture is not a supported PCM WAV file.');
}

async function json(method, route, token, body) {
  const response = await fetch(`${baseUrl}${route}`, { method, headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const value = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`${method} ${route}: ${value.error?.message || response.status}`);
  return value;
}

async function token() {
  if (process.env.NEORECALL_TOKEN) return process.env.NEORECALL_TOKEN;
  const account = process.env.NEORECALL_ACCOUNT;
  const password = process.env.NEORECALL_PASSWORD;
  if (!account || !password) throw new Error('Set NEORECALL_TOKEN or NEORECALL_ACCOUNT and NEORECALL_PASSWORD.');
  return (await json('POST', '/api/v1/auth/login', '', { account, password })).session.token;
}

async function main() {
  if (!Number.isInteger(count) || count < 1) throw new Error('Backlog chunk count must be a positive integer.');
  const bytes = fs.readFileSync(fixture); const chunkDuration = durationMs(bytes);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  const authToken = await token(); const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
  const startedAt = new Date(Date.now() - count * chunkDuration).toISOString();
  await json('POST', '/api/v1/devices', authToken, { id: deviceId, clientUuid: deviceId, name: 'Backlog load generator', platform: process.platform, kind: 'desktop', capabilities: { loadTest: true } });
  await json('POST', '/api/v1/ingest/sessions', authToken, { id: sessionId, deviceId, clientUuid: sessionId, startedAt, timezone: 'UTC', consentAttestedAt: startedAt,
    sources: [{ id: sourceId, clientUuid: sourceId, kind: 'microphone', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }] });
  let next = 0; let uploaded = 0;
  async function pump() {
    while (next < count) {
      const sequence = next; next += 1;
      const form = new FormData(); form.append('audio', new Blob([bytes], { type: 'audio/wav' }), `chunk-${sequence}.wav`);
      const response = await fetch(`${baseUrl}/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/${sequence}`, { method: 'PUT', headers: {
        Authorization: `Bearer ${authToken}`, 'Idempotency-Key': crypto.randomUUID(), 'X-Chunk-Sha256': digest,
        'X-Chunk-Duration-Ms': String(chunkDuration), 'X-Chunk-Overlap-Ms': '0', 'X-Channel-Layout': 'mono',
        'X-Monotonic-Offset-Ms': String(sequence * chunkDuration), 'X-Device-Started-At': new Date(Date.parse(startedAt) + sequence * chunkDuration).toISOString(),
        'X-Audio-Container': 'wav', 'X-Audio-Codec': 'pcm_s16le', ...(sequence === count - 1 ? { 'X-Final-Chunk': 'true' } : {}),
      }, body: form });
      if (!response.ok) throw new Error(`Chunk ${sequence} failed: ${await response.text()}`);
      uploaded += 1;
      if (uploaded % 100 === 0 || uploaded === count) process.stdout.write(`Uploaded ${uploaded}/${count}\n`);
    }
  }
  await Promise.all([pump(), pump()]);
  const endedAt = new Date(Date.parse(startedAt) + count * chunkDuration).toISOString();
  await json('PATCH', `/api/v1/ingest/sessions/${sessionId}`, authToken, { endedAt, status: 'ended', sources: [{ id: sourceId, finalSequence: count - 1 }] });
  process.stdout.write(`Queued ${count} chunks in recording ${sessionId}. Monitor /admin for drain time.\n`);
}

main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
