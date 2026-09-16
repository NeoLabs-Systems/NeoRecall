'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-gate-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const consolidation = require('../../server/services/memories/consolidation_service');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

// Closing a conversation queues one pass that can fold two speaker labels into
// one and attach voices to the people they belong to. Consolidating before that
// finishes means the model reads labels about to change — and worse, names a
// voiceprint the pass then merges away, leaving a real person wrongly named from
// evidence that no longer exists.

function seedUser() {
  const userId = crypto.randomUUID();
  getDatabase().prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')")
    .run(userId, `gate-${userId}`);
  return userId;
}

function seedConversation(userId) {
  const id = crypto.randomUUID();
  getDatabase().prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,'2026-08-01T09:00:00.000Z','2026-08-01T09:10:00.000Z','closed','test','1')`).run(id, userId);
  return id;
}

function seedJob(userId, conversationId, status) {
  const id = crypto.randomUUID();
  getDatabase().prepare(`INSERT INTO jobs (id,user_id,resource_type,resource_id,type,status,priority,max_attempts,payload_json)
    VALUES (?,?,'conversation',?, 'resolve_speakers',?,30,5,'{}')`).run(id, userId, conversationId, status);
  return id;
}

test('a conversation still waiting on speaker resolution is held back from the model', () => {
  const userId = seedUser();
  const conversationId = seedConversation(userId);
  assert.equal(consolidation.awaitingSpeakerResolution(userId, conversationId), false,
    'nothing queued, nothing to wait for');

  const jobId = seedJob(userId, conversationId, 'queued');
  assert.equal(consolidation.awaitingSpeakerResolution(userId, conversationId), true);

  getDatabase().prepare("UPDATE jobs SET status='leased' WHERE id=?").run(jobId);
  assert.equal(consolidation.awaitingSpeakerResolution(userId, conversationId), true,
    'a pass already running holds it back just as a queued one does');
});

test('a finished pass releases the conversation', () => {
  const userId = seedUser();
  const conversationId = seedConversation(userId);
  const jobId = seedJob(userId, conversationId, 'queued');
  getDatabase().prepare("UPDATE jobs SET status='completed' WHERE id=?").run(jobId);
  assert.equal(consolidation.awaitingSpeakerResolution(userId, conversationId), false);
});

test('a pass that failed for good releases the conversation rather than stranding it', () => {
  const userId = seedUser();
  const conversationId = seedConversation(userId);
  const jobId = seedJob(userId, conversationId, 'queued');
  getDatabase().prepare("UPDATE jobs SET status='failed' WHERE id=?").run(jobId);
  // Waiting is only worth it while the pass might still run. Once it cannot,
  // consolidating with provisional speaker labels beats never consolidating.
  assert.equal(consolidation.awaitingSpeakerResolution(userId, conversationId), false);
});

test('one user\'s pending resolution never holds back another\'s conversation', () => {
  const owner = seedUser();
  const other = seedUser();
  const conversationId = seedConversation(owner);
  seedJob(owner, conversationId, 'queued');
  assert.equal(consolidation.awaitingSpeakerResolution(other, conversationId), false);
});
