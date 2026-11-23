'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-neocloud-'));
process.env.NEORECALL_REQUIRE_VECTOR = 'false';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const accounts = require('../../server/services/cloud/cloud_account_service');
const archive = require('../../server/services/cloud/archive_service');
const deviceLogin = require('../../server/services/cloud/neocloud_device_login');
const { createNeoCloudSink, SINGLE_PUT_MAX_BYTES } = require('../../server/services/cloud/sinks/neocloud_sink');
const { wrapWav } = require('../../server/services/cloud/concat_recording');
const transcribe = require('../../server/workers/handlers/transcribe_handler');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const BASE = 'https://files.example.test';

function insertUser(username) {
  const id = crypto.randomUUID();
  getDatabase().prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(id, username, 'x');
  return id;
}

function json(status, body) {
  return { status, json: async () => body, text: async () => JSON.stringify(body) };
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function tempFile(name, bytes) {
  const file = path.join(process.env.NEORECALL_HOME, name);
  fs.writeFileSync(file, bytes);
  return file;
}

// A tiny in-memory NeoCloud: version, device login, folders, single and
// resumable uploads, and the device "me" route. It records every call.
function fakeNeoCloud({ partSize = 1024, tokenAnswers = [], uploadStatus = 201 } = {}) {
  const calls = [];
  const uploads = new Map();
  const stored = [];
  const answers = [...tokenAnswers];
  async function fetchImpl(url, opts = {}) {
    const parsed = new URL(url);
    const method = opts.method || 'GET';
    calls.push({ method, path: parsed.pathname, query: parsed.searchParams, headers: opts.headers || {}, body: opts.body });
    const p = parsed.pathname;
    if (p === '/api/version') return json(200, { name: 'NeoCloud', product: 'neocloud', version: '0.1.1' });
    if (p === '/api/devices/authorize') {
      return json(200, {
        deviceCode: 'device-secret', userCode: 'ABCD-EFGH',
        verificationUrl: `${BASE}/app/device?code=ABCD-EFGH`, expiresIn: 600, interval: 3,
      });
    }
    if (p === '/api/devices/token') return answers.shift() || json(428, { code: 'AUTHORIZATION_PENDING' });
    if (p === '/api/devices/me') {
      return json(200, { device: { id: 'dev-1' }, user: { id: 'u1', username: 'ada' }, quota: { used: 2048, limit: 10_000 } });
    }
    if (p === '/api/folders' && method === 'POST') {
      return json(201, { id: `folder:${JSON.parse(opts.body).path}`, type: 'folder' });
    }
    if (p === '/api/upload' && method === 'PUT') {
      if (uploadStatus !== 201) return json(uploadStatus, { error: 'nope', code: uploadStatus === 413 ? 'QUOTA_EXCEEDED' : 'X' });
      const body = Buffer.from(opts.body);
      stored.push({ parentId: parsed.searchParams.get('parentId'), name: parsed.searchParams.get('name'), body });
      return json(201, { id: 'node-1', name: parsed.searchParams.get('name') });
    }
    if (p === '/api/uploads' && method === 'POST') {
      const req = JSON.parse(opts.body);
      const id = `up-${uploads.size + 1}`;
      uploads.set(id, { ...req, id, parts: new Map() });
      return json(201, { id, partSize, partCount: Math.ceil(req.size / partSize), receivedParts: [] });
    }
    const part = /^\/api\/uploads\/([^/]+)\/parts\/(\d+)$/.exec(p);
    if (part && method === 'PUT') {
      const session = uploads.get(part[1]);
      if (!session) return json(404, { code: 'UPLOAD_NOT_FOUND' });
      session.parts.set(Number(part[2]), Buffer.from(opts.body));
      return json(200, { received: true });
    }
    const done = /^\/api\/uploads\/([^/]+)\/complete$/.exec(p);
    if (done && method === 'POST') {
      const session = uploads.get(done[1]);
      if (!session) return json(404, { code: 'UPLOAD_NOT_FOUND' });
      const body = Buffer.concat([...session.parts.entries()].sort((a, b) => a[0] - b[0]).map((entry) => entry[1]));
      if (sha256(body) !== session.sha256) return json(422, { code: 'CHECKSUM_MISMATCH' });
      stored.push({ parentId: session.parentId, name: session.name, body });
      return json(201, { id: 'node-2', name: session.name });
    }
    const get = /^\/api\/uploads\/([^/]+)$/.exec(p);
    if (get && method === 'GET') {
      const session = uploads.get(get[1]);
      if (!session) return json(404, { code: 'UPLOAD_NOT_FOUND' });
      return json(200, { id: session.id, name: session.name, size: session.size, partSize, receivedParts: [...session.parts.keys()] });
    }
    return json(404, { code: 'NOT_FOUND' });
  }
  return { fetchImpl, calls, uploads, stored };
}

test('device login refuses an address that is not NeoCloud', async () => {
  const fetchImpl = async () => json(200, { productname: 'Nextcloud' });
  await assert.rejects(
    () => deviceLogin.start('u-not', 'https://cloud.example.test', { fetchImpl }),
    (error) => error.code === 'NOT_NEOCLOUD',
  );
});

test('device login shows the NeoCloud code and approval page, then hands over the token once approved', async () => {
  const userId = 'u-login';
  const fake = fakeNeoCloud({
    tokenAnswers: [
      json(428, { code: 'AUTHORIZATION_PENDING' }),
      json(200, { token: 'nc_token', device: { id: 'dev-1', name: 'NeoRecall' }, user: { id: 'u1', username: 'ada' } }),
    ],
  });
  const started = await deviceLogin.start(userId, `${BASE}/`, { fetchImpl: fake.fetchImpl });
  assert.equal(started.status, 'connecting');
  assert.equal(started.type, 'neocloud');
  assert.equal(started.userCode, 'ABCD-EFGH');
  assert.equal(started.loginUrl, `${BASE}/app/device?code=ABCD-EFGH`);
  assert.ok(!JSON.stringify(started).includes('device-secret'));
  const authorize = fake.calls.find((call) => call.path === '/api/devices/authorize');
  assert.deepEqual(JSON.parse(authorize.body), { name: 'NeoRecall', platform: '' });

  const t0 = Date.now() + 10_000;
  const waiting = await deviceLogin.poll(userId, { fetchImpl: fake.fetchImpl, now: t0 });
  assert.equal(waiting.status, 'connecting');
  // Inside NeoCloud's interval the poll is answered without asking NeoCloud.
  const before = fake.calls.length;
  await deviceLogin.poll(userId, { fetchImpl: fake.fetchImpl, now: t0 + 500 });
  assert.equal(fake.calls.length, before);

  const done = await deviceLogin.poll(userId, { fetchImpl: fake.fetchImpl, now: t0 + 4000 });
  assert.equal(done.status, 'connected');
  assert.equal(done.token, 'nc_token');
  assert.equal(done.username, 'ada');
  assert.equal(done.deviceId, 'dev-1');
  assert.equal(deviceLogin.publicPending(userId), null);
});

test('a declined or expired NeoCloud sign-in ends the wait with a clear reason', async () => {
  for (const [status, code] of [[403, 'CLOUD_LOGIN_DENIED'], [410, 'CLOUD_LOGIN_EXPIRED']]) {
    const userId = `u-${status}`;
    const fake = fakeNeoCloud({ tokenAnswers: [json(status, {})] });
    await deviceLogin.start(userId, BASE, { fetchImpl: fake.fetchImpl });
    await assert.rejects(
      () => deviceLogin.poll(userId, { fetchImpl: fake.fetchImpl, now: Date.now() + 10_000 }),
      (error) => error.code === code,
    );
    assert.equal(deviceLogin.publicPending(userId), null);
  }
});

test('an approval link on another host is replaced by the NeoCloud server own page', () => {
  assert.equal(
    deviceLogin.approvalUrl(BASE, 'https://evil.example/phish?code=X', 'WXYZ-2345'),
    `${BASE}/app/device?code=WXYZ-2345`,
  );
  assert.equal(
    deviceLogin.approvalUrl(BASE, 'javascript:alert(1)', 'WXYZ-2345'),
    `${BASE}/app/device?code=WXYZ-2345`,
  );
});

test('small files go up in one checksummed request that cannot duplicate on retry', async () => {
  const fake = fakeNeoCloud();
  const bytes = Buffer.from('hello neocloud');
  const file = tempFile('small.bin', bytes);
  const sink = createNeoCloudSink({ baseUrl: BASE, token: 'nc_token', folder: 'NeoRecall', fetchImpl: fake.fetchImpl });
  const result = await sink.put(file, 'audio/2026-09-09/rec.wav', { capturedAt: '2026-09-09T12:00:00Z' });
  assert.equal(result.remotePath, 'NeoRecall/audio/2026-09-09/rec.wav');
  assert.equal(result.bytes, bytes.length);

  const folder = fake.calls.find((call) => call.path === '/api/folders');
  assert.deepEqual(JSON.parse(folder.body), { parentId: 'root', path: 'NeoRecall/audio/2026-09-09' });
  const put = fake.calls.find((call) => call.path === '/api/upload');
  assert.equal(put.query.get('conflict'), 'rename');
  assert.equal(put.query.get('name'), 'rec.wav');
  assert.equal(put.query.get('parentId'), 'folder:NeoRecall/audio/2026-09-09');
  assert.equal(put.headers['X-Content-SHA256'], sha256(bytes));
  assert.equal(put.headers['X-File-Created'], '2026-09-09T12:00:00.000Z');
  assert.equal(put.headers.Authorization, 'Bearer nc_token');
  assert.ok(fake.calls.every((call) => call.method !== 'DELETE'));
  assert.ok(fake.calls.every((call) => !call.path.includes('/content')));
  assert.deepEqual(fake.stored[0].body, bytes);
});

test('large recordings go up in parts and continue where a broken attempt stopped', async () => {
  const fake = fakeNeoCloud({ partSize: 1024 * 1024 });
  const bytes = crypto.randomBytes(SINGLE_PUT_MAX_BYTES + 3 * 1024 * 1024 + 17);
  const file = tempFile('large.bin', bytes);
  const sink = createNeoCloudSink({ baseUrl: BASE, token: 'nc_token', fetchImpl: fake.fetchImpl });

  // First attempt dies after the third part.
  let uploadId = null;
  let partsSent = 0;
  const flaky = async (url, opts) => {
    if (/\/parts\//.test(url) && (partsSent += 1) > 3) throw Object.assign(new Error('connection reset'), { retryable: true });
    return fake.fetchImpl(url, opts);
  };
  const flakySink = createNeoCloudSink({ baseUrl: BASE, token: 'nc_token', fetchImpl: flaky });
  await assert.rejects(() => flakySink.put(file, 'audio/day/long.wav', { onUploadStarted: (id) => { uploadId = id; } }), /reset/);
  assert.equal(uploadId, 'up-1');

  const before = fake.calls.filter((call) => /\/parts\//.test(call.path)).length;
  await sink.put(file, 'audio/day/long.wav', { resumeUploadId: uploadId, onUploadStarted: () => assert.fail('must resume, not restart') });
  const sentNow = fake.calls.filter((call) => /\/parts\//.test(call.path)).length - before;
  const totalParts = Math.ceil(bytes.length / (1024 * 1024));
  assert.equal(sentNow, totalParts - 3);
  assert.equal(fake.stored.length, 1);
  assert.ok(fake.stored[0].body.equals(bytes));
  const create = fake.calls.find((call) => call.path === '/api/uploads' && call.method === 'POST');
  assert.equal(JSON.parse(create.body).sha256, sha256(bytes));
});

test('revoked access and a full NeoCloud stop retrying with a plain explanation', async () => {
  const file = tempFile('err.bin', Buffer.from('x'));
  const revoked = createNeoCloudSink({
    baseUrl: BASE, token: 'nc_token',
    fetchImpl: async (url) => (String(url).endsWith('/api/folders') ? json(401, { code: 'UNAUTHORIZED' }) : json(200, {})),
  });
  await assert.rejects(() => revoked.put(file, 'a/b.bin'), (error) => error.code === 'CLOUD_AUTH_FAILED' && error.retryable === false
    && /Reconnect NeoCloud/.test(error.message));

  const full = createNeoCloudSink({ baseUrl: BASE, token: 'nc_token', fetchImpl: fakeNeoCloud({ uploadStatus: 413 }).fetchImpl });
  await assert.rejects(() => full.put(file, 'a/b.bin'), (error) => error.code === 'CLOUD_QUOTA_EXCEEDED' && error.retryable === false
    && /storage is full/.test(error.message));

  const busy = createNeoCloudSink({ baseUrl: BASE, token: 'nc_token', fetchImpl: fakeNeoCloud({ uploadStatus: 503 }).fetchImpl });
  await assert.rejects(() => busy.put(file, 'a/b.bin'), (error) => error.retryable === true);
});

test('a NeoCloud connection stores the token encrypted and shows quota, never the token', async () => {
  const userId = insertUser('neocloud-account');
  const fake = fakeNeoCloud();
  await accounts.connectNeoCloud(userId, { baseUrl: BASE, username: 'ada', token: 'nc_secret_token', deviceId: 'dev-1' }, { fetchImpl: fake.fetchImpl });
  const row = accounts.getRow(userId);
  assert.equal(row.type, 'neocloud');
  assert.equal(row.remote_device_id, 'dev-1');
  assert.ok(!row.secret_encrypted.includes('nc_secret_token'));
  assert.equal(accounts.credential(userId), 'nc_secret_token');
  const visible = accounts.publicAccount(userId);
  assert.equal(visible.type, 'neocloud');
  assert.deepEqual(visible.quota, { used: 2048, limit: 10_000 });
  assert.ok(!JSON.stringify(visible).includes('nc_secret_token'));
});

test('a finished recording reaches NeoCloud as one playable WAV dated to when it was recorded', async () => {
  const userId = insertUser('neocloud-recording');
  accounts.upsertConnected(userId, { type: 'neocloud', baseUrl: BASE, username: 'ada', token: 'nc_token', deviceId: 'dev-1' });
  accounts.update(userId, { audioEnabled: true });
  const db = getDatabase();
  const device = crypto.randomUUID();
  const session = crypto.randomUUID();
  const source = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(device, userId, device);
  db.prepare("INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status) VALUES (?,?,?,?,?,?, 'UTC',?,'active')")
    .run(session, userId, device, session, '2026-09-09T12:00:00Z', '2026-09-09T12:00:00Z', '2026-09-09T12:00:00Z');
  db.prepare("INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')").run(source, session, source);
  const file = tempFile('neocloud-part.wav', wrapWav(Buffer.alloc(32000), 16000, 1));
  const chunk = crypto.randomUUID();
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path,persisted_at,transcript_sha256,transcript_segment_count)
    VALUES (?,?,?,?,0,?, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',?,'wav','pcm_s16le','mono','2026-09-09T12:00:00Z',0,1000,0,'persisted_cleanup_pending',?,?,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',0)`)
    .run(chunk, userId, session, source, chunk, fs.statSync(file).size, file, '2026-09-09T12:00:01Z');
  transcribe.finishCleanup(db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunk), 0);
  db.prepare("UPDATE recording_sessions SET status='ended' WHERE id=?").run(session);

  const fake = fakeNeoCloud();
  const originalFetch = global.fetch;
  global.fetch = fake.fetchImpl;
  try {
    const result = await archive.drain(userId);
    assert.equal(result.uploaded, 1);
  } finally {
    global.fetch = originalFetch;
  }
  assert.equal(fake.stored.length, 1);
  assert.equal(fake.stored[0].body.subarray(0, 4).toString('ascii'), 'RIFF');
  const put = fake.calls.find((call) => call.path === '/api/upload');
  assert.equal(put.headers['X-File-Created'], '2026-09-09T12:00:00.000Z');
  const item = db.prepare("SELECT * FROM cloud_archive_items WHERE user_id=? AND kind='audio'").get(userId);
  assert.equal(item.state, 'uploaded');
  assert.equal(item.remote_upload_id, null);
  // The quota is refreshed after a successful drain.
  assert.deepEqual(accounts.publicAccount(userId).quota, { used: 2048, limit: 10_000 });
});

test('existing Nextcloud connections survive the NeoCloud migration unchanged', () => {
  const userId = insertUser('neocloud-migration');
  accounts.upsertConnected(userId, { baseUrl: 'https://cloud.example.test', username: 'ada', appPassword: 'app-secret' });
  const row = accounts.getRow(userId);
  assert.equal(row.type, 'nextcloud');
  assert.equal(accounts.credential(userId), 'app-secret');
  const columns = getDatabase().prepare('PRAGMA table_info(cloud_archive_items)').all().map((column) => column.name);
  assert.ok(columns.includes('remote_upload_id'));
  assert.ok(columns.includes('captured_at'));
  assert.deepEqual(getDatabase().pragma('foreign_key_check'), []);
});
