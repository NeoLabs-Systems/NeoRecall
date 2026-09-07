'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-dedupe-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_BASE_URL = 'http://127.0.0.1:1';
process.env.AI_API_MODEL = 'test/model';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const ai = require('../../server/ai/ai_engine');
const searchIndex = require('../../server/embeddings/search_index_service');
const dedupe = require('../../server/services/memories/memory_dedupe_service');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const NOW = Date.parse('2026-08-01T12:00:00.000Z');
const MINUTE = 60_000;
const OPTIONS = Object.freeze({
  memoryDedupeEnabled: true,
  memoryDedupeSimilarityThreshold: 0.88,
  memoryDedupeWindowMs: 6 * 60 * MINUTE,
  memoryDedupeMaxPairsPerRun: 20,
  memoryDedupeNeighbours: 5,
});

function at(minutesAgo) {
  return new Date(NOW - minutesAgo * MINUTE).toISOString();
}

function user() {
  const id = crypto.randomUUID();
  const db = getDatabase();
  db.prepare("INSERT INTO users(id,username,password_hash,created_at) VALUES (?,?,'x',?)").run(id, id, at(1_000));
  const runId = crypto.randomUUID();
  db.prepare(`INSERT INTO consolidation_runs(id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at)
    VALUES (?,?,?,?,100,1,'succeeded',?)`).run(runId, id, at(1_000), at(1), at(1));
  return { id, runId };
}

// A card with a controlled embedding, indexed exactly as consolidation indexes
// one. The vector is written by hand so the tests state similarity outright
// instead of depending on what a sentence model happens to think.
function memory(account, { title, summary, startMinutesAgo, endMinutesAgo, vector, edited = false, checked = false }) {
  const db = getDatabase();
  const publicId = crypto.randomUUID();
  const id = db.prepare(`INSERT INTO memories(public_id,user_id,consolidation_run_id,type,title_en,summary_en,importance,started_at,ended_at,emoji,prose_edited_at,dedupe_checked_at)
    VALUES (?,?,?,'meeting',?,?,5,?,?,'🤝',?,?) RETURNING id`)
    .get(publicId, account.id, account.runId, title, summary, at(startMinutesAgo), at(endMinutesAgo),
      edited ? at(1) : null, checked ? at(1) : null).id;
  const document = searchIndex.upsertDocument({
    userId: account.id, kind: 'memory', sourceId: id, title, body: summary, occurredAt: at(startMinutesAgo), importance: 5,
  }, db);
  if (vector) {
    const embedding = Float32Array.from(vector);
    db.prepare(`INSERT INTO search_embeddings(document_id,user_id,model_revision,dimensions,embedding,text_hash)
      VALUES (?,?,'test-model',384,?,?)`)
      .run(document.id, account.id, Buffer.from(embedding.buffer), document.text_hash);
  }
  return { id, publicId, documentId: document.id };
}

// A 384-dimension vector pointing mostly along one axis, tilted by `tilt`.
function vectorAt(tilt) {
  const values = new Array(384).fill(0);
  values[0] = 1;
  values[1] = tilt;
  return values;
}

const ALIKE = vectorAt(0.05);      // cosine ≈ 0.999 against the axis
const DIFFERENT = vectorAt(0.9);   // cosine ≈ 0.743 against the axis
const AXIS = vectorAt(0);

function stubJudge(answers) {
  const calls = [];
  const original = ai.judgeDuplicateMemories;
  ai.judgeDuplicateMemories = async (userId, left, right, evidence) => {
    calls.push({ left, right, evidence });
    const answer = answers.shift();
    if (answer instanceof Error) throw answer;
    return { value: { reasoning: 'test', sameOccasion: answer }, requestId: crypto.randomUUID() };
  };
  return { calls, restore: () => { ai.judgeDuplicateMemories = original; } };
}

test('two cards of one sitting are folded into one', async () => {
  const account = user();
  const userId = account.id;
  const first = memory(account, { title: 'Zeitplan', summary: 'Erster Teil des Gesprächs.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  const second = memory(account, { title: 'Zeitplan', summary: 'Zweiter Teil des Gesprächs.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  const judge = stubJudge([true]);
  try {
    const result = await dedupe.sweep(userId, OPTIONS);
    assert.equal(result.judged, 1);
    assert.equal(result.merged, 1);
  } finally { judge.restore(); }

  const db = getDatabase();
  const remaining = db.prepare('SELECT id,started_at,ended_at FROM memories WHERE user_id=?').all(userId);
  assert.equal(remaining.length, 1, 'One sitting, one card.');
  assert.equal(remaining[0].id, first.id, 'The older card survives, as it does for a merge by hand.');
  assert.equal(remaining[0].ended_at, at(40), 'The survivor covers the whole sitting.');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM memories WHERE id=?').get(second.id).count, 0);
  // The combined card is new text, so it goes back through the sweep rather
  // than being treated as already judged.
  assert.equal(db.prepare('SELECT dedupe_checked_at FROM memories WHERE id=?').get(first.id).dedupe_checked_at, null);
});

test('cards the model calls separate occasions are kept and never asked about twice', async () => {
  const account = user();
  const userId = account.id;
  memory(account, { title: 'Kurs, erste Stunde', summary: 'Der erste Termin.', startMinutesAgo: 300, endMinutesAgo: 290, vector: AXIS });
  memory(account, { title: 'Kurs, zweite Stunde', summary: 'Der zweite Termin.', startMinutesAgo: 120, endMinutesAgo: 110, vector: ALIKE });
  const judge = stubJudge([false, false]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).merged, 0);
    assert.equal(judge.calls.length, 1, 'One pair, one question.');
    assert.equal(getDatabase().prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 2);
    // Both are marked, so the settled question is not paid for again.
    assert.equal((await dedupe.sweep(userId, OPTIONS)).judged, 0);
    assert.equal(judge.calls.length, 1);
  } finally { judge.restore(); }
});

test('cards that merely read alike are never asked about when they are hours apart', async () => {
  const account = user();
  const userId = account.id;
  memory(account, { title: 'Standup', summary: 'Das tägliche Standup.', startMinutesAgo: 1_000, endMinutesAgo: 990, vector: AXIS });
  memory(account, { title: 'Standup', summary: 'Das tägliche Standup.', startMinutesAgo: 30, endMinutesAgo: 20, vector: ALIKE });
  const judge = stubJudge([true]);
  try {
    const result = await dedupe.sweep(userId, OPTIONS);
    assert.equal(judge.calls.length, 0, 'The time window keeps a recurring meeting out of the sweep entirely.');
    assert.equal(result.merged, 0);
  } finally { judge.restore(); }
  assert.equal(getDatabase().prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 2);
});

test('cards that do not read alike cost no model request', async () => {
  const account = user();
  const userId = account.id;
  memory(account, { title: 'Zeitplan', summary: 'Ein Gespräch über den Zeitplan.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  memory(account, { title: 'Mittagessen', summary: 'Ein Essen mit der Familie.', startMinutesAgo: 46, endMinutesAgo: 40, vector: DIFFERENT });
  const judge = stubJudge([true]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).judged, 0);
    assert.equal(judge.calls.length, 0);
  } finally { judge.restore(); }
  assert.equal(getDatabase().prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 2);
});

test('a card whose embedding is missing or stale is skipped, not judged and not marked', async () => {
  const account = user();
  const userId = account.id;
  const unembedded = memory(account, { title: 'Zeitplan', summary: 'Noch nicht indiziert.', startMinutesAgo: 60, endMinutesAgo: 50 });
  const stale = memory(account, { title: 'Zeitplan', summary: 'Text hat sich geändert.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  const db = getDatabase();
  // Rewriting a card leaves its stored vector describing wording it no longer has.
  searchIndex.upsertDocument({ userId, kind: 'memory', sourceId: stale.id, title: 'Zeitplan', body: 'Ganz anderer Text.', occurredAt: at(46), importance: 5 }, db);
  const judge = stubJudge([true]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).judged, 0);
    assert.equal(judge.calls.length, 0, 'Neither card has a vector that describes what it now says.');
  } finally { judge.restore(); }
  for (const id of [unembedded.id, stale.id]) {
    assert.equal(db.prepare('SELECT dedupe_checked_at FROM memories WHERE id=?').get(id).dedupe_checked_at, null,
      'Nothing was decided about it, so it is tried again next sweep.');
  }
});

test('a failed model request leaves both cards for the next sweep', async () => {
  const account = user();
  const userId = account.id;
  const first = memory(account, { title: 'Zeitplan', summary: 'Erster Teil.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  const second = memory(account, { title: 'Zeitplan', summary: 'Zweiter Teil.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  const judge = stubJudge([Object.assign(new Error('provider down'), { code: 'AI_UNAVAILABLE' })]);
  try {
    const result = await dedupe.sweep(userId, OPTIONS);
    assert.equal(result.merged, 0, 'A sweep that cannot ask does not guess.');
  } finally { judge.restore(); }
  const db = getDatabase();
  assert.equal(db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 2);
  for (const item of [first, second]) {
    assert.equal(db.prepare('SELECT dedupe_checked_at FROM memories WHERE id=?').get(item.id).dedupe_checked_at, null);
  }
});

test('an unaligned embedding blob is read rather than crashing the sweep', async () => {
  // SQLite returns blobs as views into a shared buffer, and one written after
  // an odd-length value does not start on a four-byte boundary.
  const account = user();
  const userId = account.id;
  const db = getDatabase();
  db.prepare("INSERT INTO app_settings(key,value_json) VALUES ('padding','\"a\"')").run();
  const first = memory(account, { title: 'Zeitplan', summary: 'Erster Teil.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  const second = memory(account, { title: 'Zeitplan', summary: 'Zweiter Teil.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  for (const item of [first, second]) {
    const stored = db.prepare('SELECT embedding FROM search_embeddings WHERE document_id=?').get(item.documentId).embedding;
    const shifted = Buffer.alloc(stored.byteLength + 1);
    stored.copy(shifted, 1);
    db.prepare('UPDATE search_embeddings SET embedding=? WHERE document_id=?')
      .run(shifted.subarray(1), item.documentId);
  }
  const judge = stubJudge([true]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).merged, 1);
  } finally { judge.restore(); }
});

test('a sweep that fails partway keeps the answers it already paid for', async () => {
  const account = user();
  const userId = account.id;
  // Two pairs far enough apart that neither is the other's neighbour: the first
  // is settled, the second is the one the provider cannot answer.
  memory(account, { title: 'Zeitplan', summary: 'Erster Teil.', startMinutesAgo: 900, endMinutesAgo: 890, vector: AXIS });
  memory(account, { title: 'Zeitplan', summary: 'Zweiter Teil.', startMinutesAgo: 886, endMinutesAgo: 880, vector: ALIKE });
  const third = memory(account, { title: 'Mittagessen', summary: 'Erster Teil.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  const fourth = memory(account, { title: 'Mittagessen', summary: 'Zweiter Teil.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  const judge = stubJudge([false, Object.assign(new Error('provider down'), { code: 'AI_UNAVAILABLE' })]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).judged, 2);
  } finally { judge.restore(); }
  const db = getDatabase();
  const marked = db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=? AND dedupe_checked_at IS NOT NULL').get(userId).count;
  assert.equal(marked, 2, 'The settled pair is not re-bought when the provider comes back.');
  for (const item of [third, fourth]) {
    assert.equal(db.prepare('SELECT dedupe_checked_at FROM memories WHERE id=?').get(item.id).dedupe_checked_at, null);
  }
});

test('an automatic merge keeps wording the reader typed themselves', async () => {
  const account = user();
  const userId = account.id;
  const first = memory(account, { title: 'Erster Teil', summary: 'Wie das Modell es schrieb.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  memory(account, { title: 'Mein eigener Titel', summary: 'Mein eigener Text.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE, edited: true });
  const judge = stubJudge([true]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).merged, 1);
  } finally { judge.restore(); }
  const survivor = getDatabase().prepare('SELECT title_en,summary_en,prose_edited_at FROM memories WHERE id=?').get(first.id);
  assert.equal(survivor.title_en, 'Mein eigener Titel', 'The cards are still folded into one; the wording is not overwritten.');
  assert.equal(survivor.summary_en, 'Mein eigener Text.');
  assert.ok(survivor.prose_edited_at, 'And the survivor is marked, so consolidation will not rename it either.');
  // No rewrite may be queued: it would replace exactly the words being kept.
  assert.equal(getDatabase().prepare("SELECT COUNT(*) count FROM jobs WHERE type='rewrite_merged_memory' AND user_id=?").get(userId).count, 0);
});

test('the sweep is bounded and can be switched off', async () => {
  const account = user();
  const userId = account.id;
  for (let index = 0; index < 4; index += 1) {
    memory(account, { title: 'Zeitplan', summary: `Teil ${index}.`, startMinutesAgo: 60 - index * 4, endMinutesAgo: 58 - index * 4, vector: index ? ALIKE : AXIS });
  }
  const judge = stubJudge([false, false, false, false, false, false]);
  try {
    assert.equal((await dedupe.sweep(userId, { ...OPTIONS, memoryDedupeMaxPairsPerRun: 2 })).judged, 2);
    assert.equal((await dedupe.sweep(userId, { ...OPTIONS, memoryDedupeEnabled: false })).judged, 0);
  } finally { judge.restore(); }
});

test('pinned and archived cards are merged like any other', async () => {
  const account = user();
  const userId = account.id;
  const db = getDatabase();
  const first = memory(account, { title: 'Zeitplan', summary: 'Erster Teil.', startMinutesAgo: 60, endMinutesAgo: 50, vector: AXIS });
  const second = memory(account, { title: 'Zeitplan', summary: 'Zweiter Teil.', startMinutesAgo: 46, endMinutesAgo: 40, vector: ALIKE });
  db.prepare('UPDATE memories SET pinned=1 WHERE id=?').run(second.id);
  db.prepare('UPDATE memories SET archived=1 WHERE id=?').run(first.id);
  const judge = stubJudge([true]);
  try {
    assert.equal((await dedupe.sweep(userId, OPTIONS)).merged, 1);
  } finally { judge.restore(); }
  const survivor = db.prepare('SELECT pinned,archived FROM memories WHERE id=?').get(first.id);
  assert.equal(survivor.pinned, 1, 'A pin on either card survives.');
  assert.equal(survivor.archived, 0, 'Only a pair that was entirely put away stays put away.');
});
