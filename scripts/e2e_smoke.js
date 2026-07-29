'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const manifest = require('../models/manifest.json');

const fixture = path.resolve(process.env.NEORECALL_E2E_AUDIO || path.join(__dirname, '..', 'test', 'fixtures', 'de_en_two_speakers.wav'));
const sourceModels = path.resolve(process.env.NEORECALL_E2E_MODELS || path.join(os.homedir(), '.neorecall', 'models'));
const timeoutMs = Number(process.env.NEORECALL_E2E_TIMEOUT_MS || 10 * 60_000);

function assert(condition, message) { if (!condition) throw new Error(message); }
function progress(message) { process.stdout.write(`[e2e] ${message}\n`); }
function wavDurationMs(bytes) {
  let offset = 12; let byteRate;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4); const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ') byteRate = bytes.readUInt32LE(offset + 16);
    if (id === 'data' && byteRate) return Math.round(size / byteRate * 1000);
    offset += 8 + size + (size % 2);
  }
  throw new Error('E2E fixture is not a supported PCM WAV file.');
}
function freePort() { return new Promise((resolve, reject) => { const server = net.createServer(); server.once('error', reject); server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)); }); }); }
function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function poll(label, operation, predicate, deadline = Date.now() + timeoutMs) {
  let last;
  while (Date.now() < deadline) {
    try { last = await operation(); if (predicate(last)) return last; } catch (error) { last = error; }
    await delay(1000);
  }
  throw new Error(`${label} timed out. Last result: ${last instanceof Error ? last.message : JSON.stringify(last)}`);
}
async function api(baseUrl, method, route, token, body) {
  const response = await fetch(`${baseUrl}${route}`, { method, signal: AbortSignal.timeout(150_000), headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
  const value = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(value.error?.message || `${method} ${route} returned ${response.status}`), { status: response.status, value });
  return value;
}

function openRouterMock() {
  let requests = 0;
  const server = http.createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString('utf8')); const system = payload.messages[0].content; const input = JSON.parse(payload.messages[1].content);
    requests += 1; let output;
    if (system.includes('consolidate personal transcripts')) {
      const conversation = input.conversations[0];
      const sectionsByStream = new Map();
      for (const item of input.conversations) {
        if (!sectionsByStream.has(item.stream)) sectionsByStream.set(item.stream, []);
        sectionsByStream.get(item.stream).push(...item.segments.map((segment) => segment.id));
      }
      const sourceSegmentIds = [...sectionsByStream.values()].flat();
      const segment = conversation.segments[0];
      output = {
        conversationSections: [...sectionsByStream.values()].map((segmentIds) => ({
          titleEn: 'Project discussion',
          summaryEn: 'A bilingual project discussion assigned follow-up work.',
          memoryWorthy: true,
          topics: ['Project planning'],
          sourceSegmentIds: segmentIds,
        })),
        entities: [], memories: [{ type: 'project_discussion', titleEn: 'Project discussion', summaryEn: 'A bilingual project discussion assigned follow-up work.', importance: 7,
          sourceSegmentIds, topics: ['Project planning'], entities: [],
          miniMemories: [{ kind: 'task', textEn: 'Follow up on the discussed project work.', importance: 7, confidence: 0.8, dueAt: null, occurredAt: null, status: 'open', sourceSegmentIds: [segment.id], entities: [] }] }],
        dailySummary: { localDate: conversation.recorded.localStartedAt.slice(0, 10), timezone: input.timezone, summaryEn: 'A bilingual project discussion produced follow-up work.' },
      };
    } else {
      output = { answer: 'The recalled discussion concerned project work and a follow-up.', citations: input.context.length ? [{ sourceId: input.context[0].sourceId }] : [] };
    }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ id: `mock-${requests}`, usage: { prompt_tokens: 20, completion_tokens: 20, cost: 0 }, choices: [{ message: { content: JSON.stringify(output) } }] }));
  });
  return { server, count: () => requests };
}

async function main() {
  assert(fs.existsSync(fixture), `E2E audio fixture not found: ${fixture}`);
  for (const model of manifest.models) for (const file of model.files) assert(fs.existsSync(path.join(sourceModels, file.path)), `Run neorecall setup first; missing ${file.path} in ${sourceModels}.`);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-e2e-')); const modelLink = path.join(home, 'models');
  fs.symlinkSync(sourceModels, modelLink, 'dir');
  const port = await freePort(); const mock = openRouterMock(); await new Promise((resolve) => mock.server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${port}`; let logs = '';
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'index.js')], { cwd: path.join(__dirname, '..'), env: { ...process.env,
    NODE_ENV: 'test', NEORECALL_HOME: home, NEORECALL_HOST: '127.0.0.1', NEORECALL_PORT: String(port), NEORECALL_REQUIRE_VECTOR: 'true',
    NEORECALL_TRANSFORMERS_LOCAL_PATH: modelLink, OPENROUTER_API_KEY: 'e2e-key',
    OPENROUTER_BASE_URL: `http://127.0.0.1:${mock.server.address().port}`, AI_DEFAULT_MODEL: 'e2e/mock', NEORECALL_MIN_NEW_MATERIAL_CHARS: '1',
    NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS: '3600000', NEORECALL_CONVERSATION_QUIET_CLOSE_MS: '1000',
  }, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', (value) => { logs = `${logs}${value}`.slice(-30_000); }); child.stderr.on('data', (value) => { logs = `${logs}${value}`.slice(-30_000); });
  try {
    progress('waiting for HTTP and model readiness');
    await poll('HTTP startup', () => fetch(`${baseUrl}/health`), (response) => response.ok);
    await poll('server readiness', () => fetch(`${baseUrl}/ready`).then((response) => response.json()), (value) => value.status === 'ready');
    progress('registering the isolated E2E user and recorder');
    const registration = await api(baseUrl, 'POST', '/api/v1/auth/register', null, { username: `e2e-${crypto.randomUUID().slice(0, 8)}`, password: `E2E-${crypto.randomBytes(18).toString('base64url')}` });
    const token = registration.session.token; const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
    const startedAt = new Date(Date.now() - 10 * 60_000).toISOString(); const bytes = fs.readFileSync(fixture); const duration = wavDurationMs(bytes);
    await api(baseUrl, 'POST', '/api/v1/devices', token, { id: deviceId, clientUuid: deviceId, name: 'E2E recorder', platform: process.platform, kind: 'desktop' });
    await api(baseUrl, 'POST', '/api/v1/ingest/sessions', token, { id: sessionId, deviceId, clientUuid: sessionId, startedAt, timezone: 'UTC', consentAttestedAt: startedAt,
      sources: [{ id: sourceId, clientUuid: sourceId, kind: 'microphone', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }] });
    const digest = crypto.createHash('sha256').update(bytes).digest('hex'); const form = new FormData(); form.append('audio', new Blob([bytes], { type: 'audio/wav' }), 'e2e.wav');
    const upload = await fetch(`${baseUrl}/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/0`, { method: 'PUT', headers: { Authorization: `Bearer ${token}`,
      'Idempotency-Key': crypto.randomUUID(), 'X-Chunk-Sha256': digest, 'X-Chunk-Duration-Ms': String(duration), 'X-Chunk-Overlap-Ms': '0', 'X-Channel-Layout': 'mono',
      'X-Monotonic-Offset-Ms': '0', 'X-Device-Started-At': startedAt, 'X-Audio-Container': 'wav', 'X-Audio-Codec': 'pcm_s16le', 'X-Final-Chunk': 'true' }, body: form });
    if (!upload.ok) throw new Error(`E2E upload failed: ${await upload.text()}`);
    const chunkId = (await upload.json()).receipt.chunkId;
    await api(baseUrl, 'PATCH', `/api/v1/ingest/sessions/${sessionId}`, token, { endedAt: new Date(Date.parse(startedAt) + duration).toISOString(), status: 'ended', sources: [{ id: sourceId, finalSequence: 0 }] });
    progress('waiting for the crash-safe terminal transcript receipt');
    const terminal = await poll('terminal transcript receipt', () => api(baseUrl, 'POST', '/api/v1/ingest/chunks/status', token, { chunkIds: [chunkId] }),
      (value) => ['transcribed', 'silent'].includes(value.receipts?.[0]?.state));
    const receipt = terminal.receipts[0]; assert(receipt.state === 'transcribed', 'Speech fixture was classified as silence.');
    assert(receipt.persistedAt && receipt.serverAudioDeletedAt && receipt.transcriptSha256, 'Terminal receipt lacks durable deletion proof.');
    const transcript = await api(baseUrl, 'GET', `/api/v1/recordings/${sessionId}/transcript`, token);
    assert(transcript.items?.length && transcript.items.some((item) => item.language), 'Original-language transcript segments were not persisted.');
    progress('waiting for token-free boundaries and the hybrid search index');
    await poll('closed conversation', () => api(baseUrl, 'GET', '/api/v1/conversations?state=closed', token), (value) => value.items?.length > 0);
    const search = await poll('hybrid search index', () => api(baseUrl, 'GET', `/api/v1/search?q=${encodeURIComponent('project report')}`, token), (value) => value.results?.length > 0);
    assert(search.results.some((item) => item.kind === 'segment'), 'Search did not return transcript evidence.');
    progress('running the single-call memory consolidation');
    const queued = await api(baseUrl, 'POST', '/api/v1/memories/consolidations', token, {}); assert(queued.queued, 'Consolidation did not queue.');
    await poll('memory consolidation', () => api(baseUrl, 'GET', '/api/v1/memories/consolidations/latest', token), (value) => value.run?.state === 'succeeded');
    const memories = await api(baseUrl, 'GET', '/api/v1/memories', token); assert(memories.items?.[0]?.title_en === 'Project discussion', 'English memory was not persisted.');
    const refined = await api(baseUrl, 'GET', '/api/v1/conversations?state=consolidated', token);
    assert(refined.items?.[0]?.title_en === 'Project discussion' && refined.items?.[0]?.summary_en, 'Conversation refinement was not persisted.');
    const daily = await api(baseUrl, 'GET', '/api/v1/daily-summaries', token); assert(daily.items?.length, 'Incremental daily summary was not persisted.');
    progress('running cited Ask over the local retrieval result');
    const answer = await api(baseUrl, 'POST', '/api/v1/search/ask', token, { question: 'What was discussed?' }); assert(answer.answer && answer.citations.length, 'Ask did not return cited context.');
    progress('verifying the durable consolidation budget gate');
    const calls = mock.count(); let gated = false;
    try { await api(baseUrl, 'POST', '/api/v1/memories/consolidations', token, {}); } catch (error) { gated = error.status === 429; }
    assert(gated && mock.count() === calls, 'Second consolidation was not blocked before an outbound request.');
    process.stdout.write('NeoRecall E2E passed: audio -> durable receipt -> transcript -> search -> memory -> cited Ask.\n');
  } catch (error) {
    throw new Error(`${error.message}\nServer log tail:\n${logs}`);
  } finally {
    child.kill('SIGTERM'); mock.server.close(); await delay(500); fs.rmSync(home, { recursive: true, force: true });
  }
}

main().catch((error) => { process.stderr.write(`${error.stack || error.message}\n`); process.exitCode = 1; });
