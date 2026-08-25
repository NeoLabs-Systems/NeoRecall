'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-continuity-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_MODEL = 'test/model';
process.env.NEORECALL_MIN_NEW_MATERIAL_CHARS = '1';
// Two runs happen back to back here; the interval gate has its own test.
process.env.NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS = '0';
process.env.NEORECALL_MIN_MEMORY_EVIDENCE_MS = '0';
process.env.NEORECALL_MIN_MEMORY_EVIDENCE_CHARS = '0';
// A stub that cannot answer should fail this file in seconds rather than wait
// out the deadline a real slow model is entitled to.
process.env.AI_REQUEST_TIMEOUT_MS = '10000';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const service = require('../../server/services/memories/consolidation_service');
const app = createApp();

let server;
let respond = () => ({});
const seenRequests = [];

test.before(async () => {
  server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      res.setHeader('Content-Type', 'application/json');
      if (body.messages[0].content.includes('running summary of one day')) {
        res.end(JSON.stringify({ id: 'daily', usage: {}, choices: [{ message: { content: JSON.stringify({
          summaryEn: 'A lesson ran through the morning.',
        }) } }] }));
        return;
      }
      seenRequests.push(body);
      // Always answer. A stub that throws would otherwise leave the request
      // hanging until the deadline, hiding the real mistake.
      let content;
      try {
        content = JSON.stringify(respond(body, seenRequests.length));
      } catch (error) {
        res.statusCode = 500;
        res.end(JSON.stringify({ error: { message: `stub failed: ${error.message}` } }));
        return;
      }
      res.end(JSON.stringify({ id: 'consolidation', usage: { prompt_tokens: 10, completion_tokens: 10 },
        choices: [{ finish_reason: 'stop', message: { content } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  process.env.AI_API_BASE_URL = `http://127.0.0.1:${server.address().port}`;
});

test.after(() => {
  server?.close();
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

async function account(username) {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username, password: 'a long and unique password' });
  const userId = registration.body.user.id;
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')")
    .run(deviceId, userId, deviceId);
  return { userId, deviceId };
}

/// One recording stream carrying one provisional conversation.
function recordStretch(context, { startedAt, endedAt, lines, sessionId = crypto.randomUUID() }) {
  const db = getDatabase();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  const conversationId = crypto.randomUUID();
  const existing = db.prepare('SELECT id FROM recording_sessions WHERE id=?').get(sessionId);
  if (!existing) {
    db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,device_ended_at,
      corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
      VALUES (?,?,?,?,?,?,?,?,'UTC',?,'ended')`)
      .run(sessionId, context.userId, context.deviceId, sessionId, startedAt, endedAt, startedAt, endedAt, startedAt);
  }
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,
    final_sequence,contiguous_terminal_sequence,closed_at) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,0,?)`)
    .run(sourceId, sessionId, sourceId, endedAt);
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,
    container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_sha256,
    transcript_segment_count,persisted_at,server_deleted_at)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono',?,0,600000,'transcribed',?,?,?,?)`)
    .run(chunkId, context.userId, sessionId, sourceId, chunkId, crypto.randomBytes(32).toString('hex'),
      startedAt, crypto.randomBytes(32).toString('hex'), lines.length, endedAt, endedAt);
  db.prepare(`INSERT INTO conversations(id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(conversationId, context.userId, startedAt, endedAt);
  const insert = db.prepare(`INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,
    started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language) VALUES (?,?,?,?,'combined',?,?,?,?,?,'en')`);
  const span = (Date.parse(endedAt) - Date.parse(startedAt)) / lines.length;
  const segmentIds = lines.map((text, index) => {
    const publicId = crypto.randomUUID();
    insert.run(publicId, context.userId, chunkId, conversationId, 'combined' && new Date(Date.parse(startedAt) + index * span).toISOString(),
      new Date(Date.parse(startedAt) + (index + 1) * span).toISOString(), index * span, (index + 1) * span, text);
    return publicId;
  });
  return { sessionId, conversationId, segmentIds };
}

async function consolidate(userId) {
  const queued = service.request(userId, { manual: true });
  assert.equal(queued.queued, true, 'a run should have been queued');
  return service.execute(queued.runId);
}

function cards(userId) {
  return getDatabase().prepare(`SELECT public_id,title_en,summary_en,started_at,ended_at,archived,emoji
    FROM memories WHERE user_id=? ORDER BY started_at`).all(userId);
}

function highlights(userId) {
  return getDatabase().prepare(`SELECT text_en FROM mini_memories WHERE user_id=? ORDER BY id`)
    .all(userId).map((row) => row.text_en);
}

/// The model's answer for a first stretch: one fresh card.
function firstLessonOutput(body) {
  const segmentIds = body.response_format.json_schema.schema
    .properties.memories.items.properties.sourceSegmentIds.items.enum;
  return {
    conversationSections: [{ titleEn: 'Op-amp integrator lesson', summaryEn: 'The group worked through the integrator.',
      memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
    entities: [],
    memories: [{ type: 'lesson', continuesPrevious: false, continuesMemoryIds: [],
      titleEn: 'Op-amp integrator lesson', summaryEn: 'The group worked through the integrator circuit.',
      emoji: '⚡', importance: 6, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [],
      miniMemories: [{ kind: 'fact', textEn: 'A 5V reference and 1k resistor limit the current to 5mA.',
        importance: 6, confidence: 0.9, dueAt: null, occurredAt: null, status: null,
        sourceSegmentIds: [segmentIds[0]], entities: [] }] }],
    dailySummary: null,
  };
}

test('a lesson recorded in two stretches becomes one card, not two', async () => {
  const context = await account('continuity-lesson');
  const stream = crypto.randomUUID();
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T08:00:00.000Z', endedAt: '2026-08-25T08:20:00.000Z',
    lines: ['We start with the integrator circuit.', 'The capacitor charges linearly.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);
  const [firstCard] = cards(context.userId);
  assert.ok(firstCard, 'the first stretch produced a card');

  // The same lesson continues minutes later, in its own provisional conversation.
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T08:22:00.000Z', endedAt: '2026-08-25T08:40:00.000Z',
    lines: ['Back to the integrator: the simulation disagrees.', 'We compare it against the hand calculation.'],
  });
  let offeredCandidates = null;
  respond = (body) => {
    const input = JSON.parse(body.messages[1].content);
    offeredCandidates = input.continuationCandidates;
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Op-amp integrator lesson', summaryEn: 'The lesson continued into simulation.',
        memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      memories: [{ type: 'lesson', continuesPrevious: false,
        // The model identifies the earlier card as the same occasion.
        continuesMemoryIds: [offeredCandidates[0].id],
        titleEn: 'Op-amp integrator lesson', summaryEn: 'The whole lesson: the integrator circuit and why the simulation disagreed.',
        emoji: '⚡', importance: 7, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [],
        miniMemories: [{ kind: 'fact', textEn: 'The simulation error came from the ideal capacitor model.',
          importance: 6, confidence: 0.9, dueAt: null, occurredAt: null, status: null,
          sourceSegmentIds: [segmentIds[0]], entities: [] }] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);

  assert.equal(offeredCandidates.length, 1, 'the earlier card was offered for comparison');
  assert.equal(offeredCandidates[0].titleEn, 'Op-amp integrator lesson');
  assert.equal(offeredCandidates[0].id, 'm1', 'candidates are aliased, never real ids');
  assert.equal(JSON.stringify(offeredCandidates).includes(firstCard.public_id), false,
    'a stable identifier never leaves the server');

  const after = cards(context.userId);
  assert.equal(after.length, 1, 'one occasion is one card');
  assert.equal(after[0].public_id, firstCard.public_id, 'the original card is extended, not replaced');
  assert.equal(after[0].summaryEn ?? after[0].summary_en,
    'The whole lesson: the integrator circuit and why the simulation disagreed.');
  assert.equal(after[0].started_at, '2026-08-25T08:00:00.000Z', 'it still starts when the lesson started');
  assert.equal(after[0].ended_at, '2026-08-25T08:40:00.000Z', 'and now runs to the end of the new material');
  assert.deepEqual(highlights(context.userId), [
    'A 5V reference and 1k resistor limit the current to 5mA.',
    'The simulation error came from the ideal capacitor model.',
  ], 'highlights from both stretches are kept');
  // Both stretches remain attached as evidence.
  const sources = getDatabase().prepare(`SELECT COUNT(*) c FROM memory_sources ms
    JOIN memories m ON m.id=ms.memory_id WHERE m.user_id=? AND ms.segment_id IS NOT NULL`).get(context.userId).c;
  assert.equal(sources, 4);
});

test('a separate occasion on the same subject stays its own card', async () => {
  const context = await account('continuity-separate');
  const stream = crypto.randomUUID();
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T09:00:00.000Z', endedAt: '2026-08-25T09:20:00.000Z',
    lines: ['Todays lesson covers the integrator.', 'We derive the output ramp.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);

  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T09:25:00.000Z', endedAt: '2026-08-25T09:45:00.000Z',
    lines: ['Next weeks lesson on the same circuit.', 'A different group repeats the derivation.'],
  });
  let offered = null;
  respond = (body) => {
    const input = JSON.parse(body.messages[1].content);
    offered = input.continuationCandidates.length;
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Integrator lesson, second group', summaryEn: 'A different group repeated the lesson.',
        memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      // Same subject, same day, same recording stream — and still a different
      // occasion. Only the model's answer decides that.
      memories: [{ type: 'lesson', continuesPrevious: false, continuesMemoryIds: [],
        titleEn: 'Integrator lesson, second group', summaryEn: 'A different group repeated the derivation.',
        emoji: '⚡', importance: 5, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [], miniMemories: [] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);
  assert.equal(offered, 1, 'the earlier card was offered for comparison');
  assert.equal(cards(context.userId).length, 2, 'nothing merges on similarity alone');
});

test('duplicate fragments of one occasion collapse into a single card', async () => {
  const context = await account('continuity-duplicates');
  const stream = crypto.randomUUID();
  for (const window of [
    { startedAt: '2026-08-25T10:00:00.000Z', endedAt: '2026-08-25T10:10:00.000Z', lines: ['Fragment one of the lesson.'] },
    { startedAt: '2026-08-25T10:12:00.000Z', endedAt: '2026-08-25T10:22:00.000Z', lines: ['Fragment two of the lesson.'] },
  ]) {
    recordStretch(context, { ...window, sessionId: stream });
    respond = firstLessonOutput;
    await consolidate(context.userId);
  }
  assert.equal(cards(context.userId).length, 2, 'two fragments exist to be reconciled');

  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T10:24:00.000Z', endedAt: '2026-08-25T10:34:00.000Z',
    lines: ['The lesson wraps up with the summary.'],
  });
  respond = (body) => {
    const input = JSON.parse(body.messages[1].content);
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Op-amp integrator lesson', summaryEn: 'The lesson closed.',
        memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      memories: [{ type: 'lesson', continuesPrevious: false,
        continuesMemoryIds: input.continuationCandidates.map((candidate) => candidate.id),
        titleEn: 'Op-amp integrator lesson', summaryEn: 'The full lesson from the circuit to the closing summary.',
        emoji: '⚡', importance: 7, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [], miniMemories: [] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);

  const after = cards(context.userId);
  assert.equal(after.length, 1, 'the fragments were absorbed into one card');
  assert.equal(after[0].started_at, '2026-08-25T10:00:00.000Z');
  assert.equal(after[0].ended_at, '2026-08-25T10:34:00.000Z');
  assert.equal(highlights(context.userId).length, 2, 'every fragment keeps its highlights');
  // Nothing that was said is lost when cards are folded together.
  const evidence = getDatabase().prepare(`SELECT COUNT(*) c FROM memory_sources ms
    JOIN memories m ON m.id=ms.memory_id WHERE m.user_id=? AND ms.segment_id IS NOT NULL`).get(context.userId).c;
  assert.equal(evidence, 3);
  const orphanedIndex = getDatabase().prepare(`SELECT COUNT(*) c FROM search_documents
    WHERE user_id=? AND kind='memory'`).get(context.userId).c;
  assert.equal(orphanedIndex, 1, 'the absorbed cards leave no stale search entries');
});

test('a claim that cannot be acted on costs the recording nothing', async () => {
  const context = await account('continuity-bad-claims');
  const stream = crypto.randomUUID();
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T11:00:00.000Z', endedAt: '2026-08-25T11:10:00.000Z',
    lines: ['A first occasion.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);

  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T11:12:00.000Z', endedAt: '2026-08-25T11:22:00.000Z',
    lines: ['A second occasion.'],
  });
  respond = (body) => {
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Second occasion', summaryEn: 'Something else happened.',
        memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      // An id that was never offered. The material is real either way.
      memories: [{ type: 'lesson', continuesPrevious: false, continuesMemoryIds: ['m99'],
        titleEn: 'Second occasion', summaryEn: 'Something else happened.',
        emoji: '⚡', importance: 5, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [], miniMemories: [] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);
  assert.equal(cards(context.userId).length, 2, 'the recording still became a card of its own');
  assert.equal(getDatabase().prepare("SELECT COUNT(*) c FROM conversations WHERE user_id=? AND quarantined_at IS NOT NULL")
    .get(context.userId).c, 0, 'and nothing was set aside over it');
});

test('a card the reader renamed or put away is left as they left it', async () => {
  const context = await account('continuity-user-intent');
  const stream = crypto.randomUUID();
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T12:00:00.000Z', endedAt: '2026-08-25T12:10:00.000Z',
    lines: ['The lesson begins.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);
  const db = getDatabase();
  const [card] = cards(context.userId);
  const token = (await request(app).post('/api/v1/auth/login')
    .send({ account: 'continuity-user-intent', password: 'a long and unique password' })).body.session.token;
  await request(app).patch(`/api/v1/memories/${card.public_id}`)
    .set('Authorization', `Bearer ${token}`)
    .send({ titleEn: 'Exam-relevant integrator lesson', emoji: '📌' }).expect(200);

  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T12:12:00.000Z', endedAt: '2026-08-25T12:22:00.000Z',
    lines: ['The lesson continues.'],
  });
  respond = (body) => {
    const input = JSON.parse(body.messages[1].content);
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Op-amp integrator lesson', summaryEn: 'The lesson continued.',
        memoryWorthy: true, continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      memories: [{ type: 'lesson', continuesPrevious: false,
        continuesMemoryIds: input.continuationCandidates.map((candidate) => candidate.id),
        titleEn: 'Op-amp integrator lesson', summaryEn: 'The lesson including the second stretch.',
        emoji: '⚡', importance: 6, sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [], miniMemories: [] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);

  const [extended] = cards(context.userId);
  assert.equal(extended.title_en, 'Exam-relevant integrator lesson', 'the reader named this card');
  assert.equal(extended.emoji, '📌');
  assert.equal(extended.summary_en, 'The lesson including the second stretch.',
    'the account of the occasion still grows');
  assert.equal(db.prepare('SELECT title FROM search_documents WHERE user_id=? AND kind=?')
    .get(context.userId, 'memory').title, 'Exam-relevant integrator lesson',
  'and search finds it under the name they gave it');

  // Putting a card away means it stops collecting new material.
  await request(app).patch(`/api/v1/memories/${extended.public_id}`)
    .set('Authorization', `Bearer ${token}`).send({ archived: true }).expect(200);
  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T12:24:00.000Z', endedAt: '2026-08-25T12:34:00.000Z',
    lines: ['Another stretch after archiving.'],
  });
  let candidateCount = null;
  respond = (body) => {
    candidateCount = JSON.parse(body.messages[1].content).continuationCandidates.length;
    return firstLessonOutput(body);
  };
  await consolidate(context.userId);
  assert.equal(candidateCount, 0, 'an archived card is not offered as somewhere to file new material');
  assert.equal(cards(context.userId).length, 2, 'the new material is visible instead of hidden');
  assert.equal(cards(context.userId).find((row) => row.public_id === extended.public_id).archived, 1,
    'and the card they put away stays put away');
});

test('an unrelated recording from hours earlier is never even offered', async () => {
  const context = await account('continuity-bounds');
  recordStretch(context, {
    startedAt: '2026-08-25T06:00:00.000Z', endedAt: '2026-08-25T06:10:00.000Z',
    lines: ['A morning conversation on its own recording.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);

  // Hours later, a different recording. Bounding the candidates is what keeps
  // the prompt small; it is not what decides a merge.
  recordStretch(context, {
    startedAt: '2026-08-25T18:00:00.000Z', endedAt: '2026-08-25T18:10:00.000Z',
    lines: ['An evening conversation on another recording.'],
  });
  let offered = null;
  respond = (body) => {
    offered = JSON.parse(body.messages[1].content).continuationCandidates;
    return firstLessonOutput(body);
  };
  await consolidate(context.userId);
  assert.deepEqual(offered, [], 'nothing from that distance is worth a place in the prompt');
  assert.equal(cards(context.userId).length, 2);
});

test('the model is told what a continuation is and given the shape to answer in', async () => {
  const context = await account('continuity-contract');
  recordStretch(context, {
    startedAt: '2026-08-25T13:00:00.000Z', endedAt: '2026-08-25T13:10:00.000Z',
    lines: ['A single stretch.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);
  const body = seenRequests.at(-1);
  const instructions = body.messages[0].content;
  assert.match(instructions, /continuationCandidates/,
    'the instructions explain what the candidate cards are');
  assert.match(instructions, /SAME sitting/,
    'and that identity of the sitting is the question being asked');
  assert.match(instructions, /continuationReasoning/,
    'and that the reason is written before the answer');
  // With nothing to continue, the grammar itself forbids inventing a claim.
  assert.equal(body.response_format.json_schema.schema
    .properties.memories.items.properties.continuesMemoryIds.maxItems, 0);
});

test('folding cards together never attaches the same line twice', async () => {
  const context = await account('continuity-no-double-evidence');
  const stream = crypto.randomUUID();
  const first = recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T15:00:00.000Z', endedAt: '2026-08-25T15:10:00.000Z',
    lines: ['The opening of the session.'],
  });
  respond = firstLessonOutput;
  await consolidate(context.userId);
  const db = getDatabase();
  const [card] = cards(context.userId);
  // Two cards that overlap on the very same evidence, which is what a repeat
  // pass over shared material produces.
  const overlapping = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    SELECT ?,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id
    FROM memories WHERE public_id=? RETURNING id`).get(crypto.randomUUID(), card.public_id);
  const segmentRow = db.prepare('SELECT id FROM transcript_segments WHERE public_id=?').get(first.segmentIds[0]);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id,segment_id) VALUES (?,NULL,?)')
    .run(overlapping.id, segmentRow.id);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id,segment_id) VALUES (?,?,NULL)')
    .run(overlapping.id, first.conversationId);

  recordStretch(context, {
    sessionId: stream,
    startedAt: '2026-08-25T15:12:00.000Z', endedAt: '2026-08-25T15:22:00.000Z',
    lines: ['The rest of the same session.'],
  });
  respond = (body) => {
    const input = JSON.parse(body.messages[1].content);
    const segmentIds = body.response_format.json_schema.schema
      .properties.memories.items.properties.sourceSegmentIds.items.enum;
    return {
      conversationSections: [{ titleEn: 'Session', summaryEn: 'It continued.', memoryWorthy: true,
        continuesPrevious: false, topics: ['Electronics'], sourceSegmentIds: segmentIds }],
      entities: [],
      memories: [{ type: 'lesson', continuesPrevious: false,
        continuesMemoryIds: input.continuationCandidates.map((candidate) => candidate.id),
        titleEn: 'Session', summaryEn: 'The whole session.', emoji: '⚡', importance: 6,
        sourceSegmentIds: segmentIds, topics: ['Electronics'], entities: [], miniMemories: [] }],
      dailySummary: null,
    };
  };
  await consolidate(context.userId);

  assert.equal(cards(context.userId).length, 1);
  const duplicated = db.prepare(`SELECT COUNT(*) c FROM (
    SELECT memory_id,conversation_id,segment_id FROM memory_sources
    GROUP BY memory_id,conversation_id,segment_id HAVING COUNT(*)>1)`).get().c;
  assert.equal(duplicated, 0, 'the same evidence is never attached to a card twice');
  const detail = require('../../server/services/memories/memory_service')
    .memoryDetail(context.userId, cards(context.userId)[0].public_id);
  const texts = detail.sources.map((source) => source.text);
  assert.equal(new Set(texts).size, texts.length, 'and the card never shows a line twice');
});
