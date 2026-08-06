'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-error-detail-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_MODEL = 'test/model';
process.env.NEORECALL_MIN_NEW_MATERIAL_CHARS = '1';
process.env.NEORECALL_MIN_AI_AUDIO_MS = '0';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const consolidation = require('../../server/services/memories/consolidation_service');

migrate();
let server;
test.after(() => { server?.close(); closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('a validation failure keeps its specific reason, not just its code', async () => {
  // Reproduces the exact gap hit while diagnosing a real failure: the throw
  // sites in conversation_refinement_service and consolidation_service already
  // carry a precise message, but only error_code used to survive into storage.
  // Without the message, diagnosing a failure meant re-sending the same paid
  // request just to see it again.
  const db = getDatabase();
  const userId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,?)").run(userId, `u-${userId.slice(0, 8)}`, 'hash');
  const conversationId = crypto.randomUUID();
  const segmentPublicId = crypto.randomUUID();
  const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID(); const chunkId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?, 'UTC',?,'ended')`).run(sessionId, userId, deviceId, sessionId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z', '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z', '2026-08-01T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence,closed_at)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,0,?)`).run(sourceId, sessionId, sourceId, '2026-08-01T10:05:00.000Z');
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_sha256,transcript_segment_count,persisted_at,server_deleted_at)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono','2026-08-01T10:00:00.000Z',0,300000,'transcribed',?,1,?,?)`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, 'a'.repeat(64), 'b'.repeat(64), '2026-08-01T10:05:00.000Z', '2026-08-01T10:05:01.000Z');
  db.prepare(`INSERT INTO conversations(id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(conversationId, userId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z');
  const secondSegmentPublicId = crypto.randomUUID();
  db.prepare(`INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,?, 'combined',?,?,0,150000,?,'de')`).run(segmentPublicId, userId, chunkId, conversationId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:02:00.000Z', 'Erstes Segment.');
  db.prepare(`INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,?, 'combined',?,?,150000,300000,?,'de')`).run(secondSegmentPublicId, userId, chunkId, conversationId, '2026-08-01T10:03:00.000Z', '2026-08-01T10:05:00.000Z', 'Zweites Segment.');
  const runId = crypto.randomUUID();
  db.prepare(`INSERT INTO consolidation_runs(id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at)
    VALUES (?,?,?,?,20,1,'reserved',?)`).run(runId, userId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z', new Date().toISOString());
  db.prepare(`INSERT INTO jobs (id,user_id,resource_type,resource_id,type,status,priority,max_attempts,payload_json)
    VALUES (?,?,?,?,'consolidate_memories','queued',80,1,?)`).run(crypto.randomUUID(), userId, 'consolidation_run', runId, JSON.stringify({ runId, conversationIds: [conversationId] }));

  // A response that covers only the first of the two real segments: schema-valid
  // (at least one section, real segment IDs), but triggers the refinement
  // service's specific, pre-existing "omitted transcript segments" message.
  server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      const input = JSON.parse(payload.messages[1].content);
      const firstAlias = input.conversations[0].segments[0].id;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ id: 'r1', usage: {}, choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({
        conversationSections: [{ titleEn: 'Partial', summaryEn: 'Only the first segment.', memoryWorthy: false, topics: [], sourceSegmentIds: [firstAlias] }],
        entities: [], memories: [], dailySummary: null,
      }) } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  process.env.AI_API_BASE_URL = `http://127.0.0.1:${server.address().port}`;

  await assert.rejects(() => consolidation.execute(runId));

  const run = db.prepare('SELECT state,error_code,error_message FROM consolidation_runs WHERE id=?').get(runId);
  assert.equal(run.state, 'failed');
  assert.equal(run.error_code, 'AI_REFERENCE_INVALID');
  assert.equal(run.error_message, 'Conversation sections omitted transcript segments.');

  // The same detail is what an operator sees through the ordinary API surface.
  const { run: latest } = consolidation.latest(userId);
  assert.equal(latest.error_message, run.error_message);
});
