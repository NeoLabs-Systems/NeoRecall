'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-events-'));
const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { getDatabase } = require('../../server/db/database');
const events = require('../../server/services/events/event_outbox_service');

test('event outbox polling returns later rows in order', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(userId, 'events-user', 'hash');
  const expires = new Date(Date.now() + 60_000).toISOString();
  db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
    VALUES (?,'chunk.persisted','audio_chunk','a','{}',?)`).run(userId, expires);
  db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
    VALUES (?,'chunk.persisted','audio_chunk','b','{}',?)`).run(userId, expires);
  const first = events.pollAfter(userId, 0);
  assert.equal(first.length, 2);
  const rest = events.pollAfter(userId, first[0].id);
  assert.equal(rest.length, 1);
  assert.equal(rest[0].id, first[1].id);
});
