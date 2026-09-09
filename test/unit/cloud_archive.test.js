'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-cloud-'));
process.env.NEORECALL_REQUIRE_VECTOR = 'false';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const accounts = require('../../server/services/cloud/cloud_account_service');
const archive = require('../../server/services/cloud/archive_service');
const userExport = require('../../server/services/cloud/user_export_service');
const loginFlow = require('../../server/services/cloud/nextcloud_login_flow');
const { createWebDavSink } = require('../../server/services/cloud/sinks/webdav_sink');
const transcribe = require('../../server/workers/handlers/transcribe_handler');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

function insertUser(username) {
  const id = crypto.randomUUID();
  getDatabase().prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,?)").run(id, username, 'x');
  return id;
}

function seedChunk(userId, file) {
  const db = getDatabase();
  const device = crypto.randomUUID();
  const session = crypto.randomUUID();
  const source = crypto.randomUUID();
  const chunk = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(device, userId, device);
  db.prepare("INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status) VALUES (?,?,?,?,?,?, 'UTC',?,'active')")
    .run(session, userId, device, session, '2026-09-09T12:00:00Z', '2026-09-09T12:00:00Z', '2026-09-09T12:00:00Z');
  db.prepare("INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')").run(source, session, source);
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,temporary_path,persisted_at,transcript_sha256,transcript_segment_count)
    VALUES (?,?,?,?,0,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',4,'wav','pcm_s16le','mono','2026-09-09T12:00:00Z',0,1000,'persisted_cleanup_pending',?,?, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',0)`)
    .run(chunk, userId, session, source, chunk, file, '2026-09-09T12:00:01Z');
  return { chunk, session };
}

function zipEntry(buffer, name) {
  let offset = 0;
  while (offset + 30 <= buffer.length) {
    if (buffer.readUInt32LE(offset) !== 0x04034b50) break;
    const method = buffer.readUInt16LE(offset + 8);
    const compSize = buffer.readUInt32LE(offset + 18);
    const nameLen = buffer.readUInt16LE(offset + 26);
    const extra = buffer.readUInt16LE(offset + 28);
    const entryName = buffer.subarray(offset + 30, offset + 30 + nameLen).toString();
    const start = offset + 30 + nameLen + extra;
    const data = buffer.subarray(start, start + compSize);
    if (entryName === name) return method === 8 ? zlib.inflateRawSync(data) : data;
    offset = start + compSize;
  }
  throw new Error(`zip entry missing: ${name}`);
}

test('Login Flow v2 stores an app password after a successful poll', async () => {
  const userId = insertUser('cloud-login');
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push({ url: String(url), method: opts.method, body: opts.body });
    if (String(url).endsWith('/index.php/login/v2')) {
      return {
        status: 200,
        json: async () => ({
          login: 'https://cloud.example.test/index.php/login/v2/flow/abc',
          poll: { token: 'tok', endpoint: 'https://cloud.example.test/index.php/login/v2/poll' },
        }),
      };
    }
    if (String(url).endsWith('/poll')) {
      return {
        status: 200,
        json: async () => ({ loginName: 'ada', appPassword: 'app-secret' }),
      };
    }
    throw new Error(`unexpected fetch ${opts.method} ${url}`);
  };
  const started = await loginFlow.start(userId, 'https://cloud.example.test', { fetchImpl });
  assert.equal(started.status, 'connecting');
  const result = await loginFlow.poll(userId, { fetchImpl });
  accounts.upsertConnected(userId, result);
  const pub = accounts.publicAccount(userId);
  assert.equal(pub.connected, true);
  assert.equal(pub.username, 'ada');
  assert.equal(pub.audioEnabled, false);
  assert.ok(!JSON.stringify(pub).includes('app-secret'));
  assert.equal(accounts.appPassword(userId), 'app-secret');
  accounts.disconnect(userId);
  assert.equal(accounts.get(userId), null);
  assert.equal(accounts.appPassword(userId), null);
});

test('WebDAV sink issues MKCOL then PUT and never GET', async () => {
  const file = path.join(process.env.NEORECALL_HOME, 'clip.wav');
  fs.writeFileSync(file, 'RIFF');
  const methods = [];
  const sink = createWebDavSink({
    baseUrl: 'https://cloud.example.test',
    username: 'ada',
    password: 'secret',
    fetchImpl: async (url, opts) => {
      methods.push(opts.method);
      assert.ok(!['GET', 'PROPFIND', 'DELETE'].includes(opts.method));
      return { status: opts.method === 'PUT' ? 201 : 201, text: async () => '' };
    },
  });
  const result = await sink.put(file, 'audio/2026-09-09/session/chunk.wav');
  assert.equal(result.bytes, 4);
  assert.ok(methods.includes('MKCOL'));
  assert.equal(methods.at(-1), 'PUT');
});

test('a user export contains only that user and no secrets', () => {
  const alice = insertUser('alice-export');
  const bob = insertUser('bob-export');
  accounts.upsertConnected(alice, { baseUrl: 'https://cloud.example.test', username: 'ada', appPassword: 'hidden-app-password' });
  const packed = userExport.build(alice);
  const data = JSON.parse(zipEntry(packed, 'data.json').toString());
  const manifest = JSON.parse(zipEntry(packed, 'manifest.json').toString());
  assert.equal(data.account.username, 'alice-export');
  assert.equal(manifest.username, 'alice-export');
  const dumped = JSON.stringify(data);
  assert.ok(!dumped.includes('bob-export'));
  assert.ok(!dumped.includes('hidden-app-password'));
  assert.ok(!dumped.includes('password_hash'));
  accounts.disconnect(alice);
  assert.ok(bob);
});

test('audio staging does not block a terminal receipt when Nextcloud is down', async () => {
  const userId = insertUser('cloud-audio');
  accounts.upsertConnected(userId, { baseUrl: 'https://cloud.example.test', username: 'ada', appPassword: 'secret' });
  accounts.update(userId, { audioEnabled: true });
  const file = path.join(process.env.NEORECALL_HOME, 'chunk.wav');
  fs.writeFileSync(file, 'RIFF');
  const { chunk } = seedChunk(userId, file);
  const row = getDatabase().prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunk);
  const receipt = transcribe.finishCleanup(row, 0);
  assert.equal(receipt.state, 'silent');
  assert.equal(fs.existsSync(file), false);
  const pending = getDatabase().prepare("SELECT * FROM cloud_archive_items WHERE user_id=? AND kind='audio'").get(userId);
  assert.equal(pending.state, 'queued');
  assert.ok(fs.existsSync(pending.local_path));

  const fetchImpl = async () => { throw Object.assign(new Error('down'), { retryable: true }); };
  const originalFetch = global.fetch;
  global.fetch = fetchImpl;
  try {
    await assert.rejects(() => archive.drain(userId), /down/);
  } finally {
    global.fetch = originalFetch;
  }
  const still = getDatabase().prepare('SELECT * FROM cloud_archive_items WHERE id=?').get(pending.id);
  assert.equal(still.state, 'queued');
  assert.equal(getDatabase().prepare('SELECT state FROM audio_chunks WHERE id=?').get(chunk).state, 'silent');
});
