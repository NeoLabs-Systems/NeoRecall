'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-consolidation-'));
process.env.OPENROUTER_API_KEY = 'test-key';
process.env.AI_DEFAULT_MODEL = 'test/model';
process.env.NEORECALL_MIN_NEW_MATERIAL_CHARS = '1';
process.env.NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS = '3600000';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const service = require('../../server/services/memories/consolidation_service');
const app = createApp();
let server;
test.after(() => { server?.close(); closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('one outbound request creates English memories and a durable interval gate', async () => {
  let outbound = 0; let outboundBody;
  const segmentPublicId = crypto.randomUUID();
  const secondSegmentPublicId = crypto.randomUUID();
  const conversationId = crypto.randomUUID();
  server = http.createServer((req, res) => {
    outbound += 1;
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      outboundBody = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ id: 'generation-test', usage: { prompt_tokens: 100, completion_tokens: 50, cost: 0.001 }, choices: [{ message: { content: JSON.stringify({
      conversationSections: [
        { titleEn: 'Release planning', summaryEn: 'Alex accepted responsibility for the release plan.', memoryWorthy: true,
          topics: ['Release planning'], sourceSegmentIds: ['s1'] },
        { titleEn: 'Launch review', summaryEn: 'The team reviewed launch readiness.', memoryWorthy: true,
          topics: ['Launch'], sourceSegmentIds: ['s2'] },
      ],
      entities: [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Alex', displayName: 'Alex', aliases: [] }],
      memories: [{ type: 'project_discussion', titleEn: 'Project planning', summaryEn: 'Alex agreed to prepare the release plan.', importance: 8,
        sourceSegmentIds: ['s1'],
        topics: ['Release planning'], entities: [{ ref: 'person-1', role: 'participant' }], miniMemories: [{ kind: 'promise', textEn: 'Alex promised to prepare the release plan.',
          importance: 8, confidence: 0.95, dueAt: null, occurredAt: '2026-07-13T10:04:00.000Z', status: 'open', sourceSegmentIds: ['s1'], entities: [{ ref: 'person-1', role: 'promisor' }] }] }],
      dailySummary: { localDate: '2026-07-13', timezone: 'UTC', summaryEn: 'The release plan was discussed and assigned to Alex.' },
      }) } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  process.env.OPENROUTER_BASE_URL = `http://127.0.0.1:${server.address().port}`;
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'memory-user', password: 'a long and unique password' });
  const userId = registration.body.user.id; const db = getDatabase();
  const device = crypto.randomUUID(); const session = crypto.randomUUID(); const source = crypto.randomUUID(); const chunk = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(device, userId, device);
  db.prepare("INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status) VALUES (?,?,?,?,?,?,?,?, 'UTC',?,'ended')")
    .run(session, userId, device, session, '2026-07-13T10:00:00.000Z', '2026-07-13T10:05:00.000Z', '2026-07-13T10:00:00.000Z', '2026-07-13T10:05:00.000Z', '2026-07-13T09:59:00.000Z');
  db.prepare("INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence,closed_at) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,0,?)").run(source, session, source, '2026-07-13T10:05:00.000Z');
  db.prepare("INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_sha256,transcript_segment_count,persisted_at,server_deleted_at) VALUES (?,?,?,?,0,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'wav','pcm_s16le','mono','2026-07-13T10:00:00.000Z',0,30000,'transcribed','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',2,?,?)")
    .run(chunk, userId, session, source, chunk, '2026-07-13T10:05:00.000Z', '2026-07-13T10:05:01.000Z');
  db.prepare("INSERT INTO conversations(id,user_id,started_at,ended_at,state,boundary_method,boundary_version) VALUES (?,?,?,?,'closed','test','1')").run(conversationId, userId, '2026-07-13T10:00:00.000Z', '2026-07-13T10:05:00.000Z');
  db.prepare("INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language) VALUES (?,?,?,?, 'combined',?,?,0,300000,?,'de')")
    .run(segmentPublicId, userId, chunk, conversationId, '2026-07-13T10:00:00.000Z', '2026-07-13T10:02:00.000Z', 'Alex übernimmt den Release-Plan.');
  db.prepare("INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language) VALUES (?,?,?,?, 'combined',?,?,300000,600000,?,'de')")
    .run(secondSegmentPublicId, userId, chunk, conversationId, '2026-07-13T10:03:00.000Z', '2026-07-13T10:05:00.000Z', 'Danach prüft das Team die Launch-Bereitschaft.');
  const queued = service.request(userId, { manual: true });
  assert.equal(queued.queued, true);
  await service.execute(queued.runId);
  assert.equal(outbound, 1);
  assert.equal(outboundBody.response_format.type, 'json_schema');
  assert.equal(outboundBody.response_format.json_schema.strict, true);
  assert.deepEqual(outboundBody.response_format.json_schema.schema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum, ['s1', 's2']);
  assert.equal(outboundBody.provider.require_parameters, true);
  assert.equal(outboundBody.max_tokens, 8000);
  assert.equal(outboundBody.messages[1].content.includes(conversationId), false);
  assert.equal(outboundBody.messages[1].content.includes(segmentPublicId), false);
  const storedMemory = db.prepare('SELECT title_en,started_at,ended_at FROM memories WHERE user_id=?').get(userId);
  assert.deepEqual(storedMemory, { title_en: 'Project planning', started_at: '2026-07-13T10:00:00.000Z', ended_at: '2026-07-13T10:02:00.000Z' });
  assert.equal(db.prepare('SELECT text_en FROM mini_memories WHERE user_id=?').get(userId).text_en, 'Alex promised to prepare the release plan.');
  assert.equal(db.prepare('SELECT summary_en FROM daily_summaries WHERE user_id=?').get(userId).summary_en, 'The release plan was discussed and assigned to Alex.');
  assert.deepEqual(db.prepare('SELECT title_en,summary_en,state,boundary_version FROM conversations WHERE id=?').get(conversationId), {
    title_en: 'Release planning',
    summary_en: 'Alex accepted responsibility for the release plan.',
    state: 'consolidated',
    boundary_version: '3',
  });
  assert.deepEqual(db.prepare('SELECT title_en,summary_en,state FROM conversations WHERE user_id=? ORDER BY started_at').all(userId), [
    {
      title_en: 'Release planning',
      summary_en: 'Alex accepted responsibility for the release plan.',
      state: 'consolidated',
    },
    {
      title_en: 'Launch review',
      summary_en: 'The team reviewed launch readiness.',
      state: 'consolidated',
    },
  ]);
  assert.equal(db.prepare('SELECT source_count FROM daily_summaries WHERE user_id=?').get(userId).source_count, 2);
  const gated = service.eligibility(userId); assert.equal(gated.eligible, false); assert.equal(gated.reason, 'interval'); assert.equal(outbound, 1);
});
