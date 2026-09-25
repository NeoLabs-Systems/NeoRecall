'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-admin-access-'));

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const access = require('../../server/services/auth/admin_access_service');
const retired = require('../../server/services/auth/retired_admin_credentials');
const app = createApp();
test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const CLI = path.join(__dirname, '..', '..', 'bin', 'neorecall.js');
const PASSWORD = 'a long and unique password';
const bearer = (token) => ({ Authorization: `Bearer ${token}` });

async function register(username) {
  const response = await request(app).post('/api/v1/auth/register').send({ username, password: PASSWORD }).expect(201);
  return { id: response.body.user.id, role: response.body.user.role, token: response.body.session.token };
}

let owner;
let member;

test('the first account is the admin and reaches the admin API; later accounts do not', async () => {
  owner = await register('owner');
  member = await register('member');
  assert.equal(owner.role, 'admin');
  assert.equal(member.role, 'user');

  const stats = await request(app).get('/api/v1/admin/stats').set(bearer(owner.token)).expect(200);
  assert.equal(stats.body.version, require('../../package.json').version);
  const refused = await request(app).get('/api/v1/admin/stats').set(bearer(member.token)).expect(403);
  assert.equal(refused.body.error.code, 'ADMIN_REQUIRED');
  await request(app).get('/api/v1/admin/stats').expect(401);
});

test('an admin account’s API key does not reach the admin API', async () => {
  const key = await request(app).post('/api/v1/api-keys').set(bearer(owner.token))
    .send({ name: 'everything', scopes: ['*'] }).expect(201);
  const refused = await request(app).get('/api/v1/admin/users').set(bearer(key.body.token)).expect(403);
  assert.equal(refused.body.error.code, 'SESSION_REQUIRED');
});

test('granting and revoking applies to a session that is already signed in', async () => {
  assert.equal(access.grantAdmin('MEMBER', { source: 'test' }).changed, true, 'usernames match without case');
  await request(app).get('/api/v1/admin/stats').set(bearer(member.token)).expect(200);
  const me = await request(app).get('/api/v1/auth/me').set(bearer(member.token)).expect(200);
  assert.equal(me.body.user.role, 'admin');

  assert.equal(access.revokeAdmin('member', { source: 'test' }).changed, true);
  await request(app).get('/api/v1/admin/stats').set(bearer(member.token)).expect(403);
  assert.equal(access.revokeAdmin('member', { source: 'test' }).changed, false);

  const actions = getDatabase().prepare(`SELECT action, metadata_json FROM audit_log
    WHERE affected_user_id = ? AND action LIKE 'admin_%' ORDER BY id`).all(member.id);
  assert.deepEqual(actions.map((row) => row.action), ['admin_granted', 'admin_revoked']);
  assert.deepEqual(JSON.parse(actions[0].metadata_json), { source: 'test' });
});

test('an admin cannot disable an admin account, but can disable and re-enable others', async () => {
  const own = await request(app).patch(`/api/v1/admin/users/${owner.id}`).set(bearer(owner.token))
    .send({ disabled: true }).expect(403);
  assert.equal(own.body.error.code, 'ADMIN_ACCOUNT');

  await request(app).patch(`/api/v1/admin/users/${member.id}`).set(bearer(owner.token)).send({ disabled: true }).expect(204);
  await request(app).get('/api/v1/auth/me').set(bearer(member.token)).expect(401);
  await request(app).patch(`/api/v1/admin/users/${member.id}`).set(bearer(owner.token)).send({ disabled: false }).expect(204);
  member.token = (await request(app).post('/api/v1/auth/login').send({ account: 'member', password: PASSWORD }).expect(200)).body.session.token;
});

test('the audit log names the admin who acted', async () => {
  const response = await request(app).get('/api/v1/admin/audit?limit=20').set(bearer(owner.token)).expect(200);
  const disabled = response.body.entries.find((entry) => entry.action === 'user_disabled');
  assert.equal(disabled.actor_type, 'admin');
  assert.equal(disabled.actor_username, 'owner');
  assert.equal(disabled.affected_username, 'member');
});

test('an admin cannot delete their own account until admin is revoked', async () => {
  const refused = await request(app).delete('/api/v1/auth/account').set(bearer(owner.token))
    .send({ password: PASSWORD }).expect(403);
  assert.equal(refused.body.error.code, 'ADMIN_SELF_DELETE');
  // Ordinary accounts keep deleting themselves as before.
  const leaving = await register('leaving');
  await request(app).delete('/api/v1/auth/account').set(bearer(leaving.token)).send({ password: PASSWORD }).expect(204);
});

test('NEORECALL_ADMIN_USERS grants existing accounts, reserves missing names, and respects a CLI revoke', async () => {
  const listed = await register('listed');
  const env = { [access.ADMIN_USERS_ENV_KEY]: 'listed, not-yet' };
  assert.deepEqual(access.applyEnvAdminGrants(env), { granted: ['listed'], missing: ['not-yet'], revoked: [] });
  assert.deepEqual(access.applyEnvAdminGrants(env), { granted: [], missing: ['not-yet'], revoked: [] });

  process.env[access.ADMIN_USERS_ENV_KEY] = 'not-yet, JÖRG';
  try {
    const taken = await request(app).post('/api/v1/auth/register').send({ username: 'NOT-YET', password: PASSWORD }).expect(409);
    assert.equal(taken.body.error.code, 'USERNAME_RESERVED');
    assert.match(taken.body.error.message, /NEORECALL_ADMIN_USERS/);
    // Case folds the way SQLite's NOCASE does, ASCII only: "Jörg" is another
    // name than "JÖRG" to the grant, so it is not reserved, and "JÖRG" is.
    await request(app).post('/api/v1/auth/register').send({ username: 'Jörg', password: PASSWORD }).expect(201);
    const listed = await request(app).post('/api/v1/auth/register').send({ username: 'jÖrg', password: PASSWORD }).expect(409);
    assert.equal(listed.body.error.code, 'USERNAME_RESERVED');
    assert.deepEqual(access.applyEnvAdminGrants().missing, ['not-yet', 'JÖRG']);
  } finally {
    delete process.env[access.ADMIN_USERS_ENV_KEY];
  }

  access.revokeAdmin('listed', { source: 'cli' });
  assert.deepEqual(access.applyEnvAdminGrants(env).revoked, ['listed']);
  assert.equal(access.isAdminUser(listed.id), false, 'a revoke outlasts the env list');
});

test('startup reports an install with accounts but no admin', () => {
  assert.equal(access.needsAdminGrant(), false);
  access.revokeAdmin('owner', { source: 'test' });
  assert.equal(access.needsAdminGrant(), true);
  access.grantAdmin('owner', { source: 'test' });
});

test('the CLI lists, grants and revokes admin', () => {
  const run = (...args) => {
    const result = spawnSync(process.execPath, [CLI, 'admin', ...args, '--json'], { encoding: 'utf8', env: { ...process.env } });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout.trim().split('\n').pop());
  };
  assert.deepEqual(run(), { admins: ['owner'] });
  assert.deepEqual(run('grant', 'member'), { username: 'member', changed: true });
  assert.deepEqual(run(), { admins: ['owner', 'member'] });
  assert.deepEqual(run('revoke', 'member'), { username: 'member', changed: true });
  const missing = spawnSync(process.execPath, [CLI, 'admin', 'grant', 'nobody'], { encoding: 'utf8', env: { ...process.env } });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /No account named "nobody"/);
});

test('the retired dashboard credentials are removed from the env file', () => {
  const envFile = path.join(process.env.NEORECALL_HOME, 'retire.env');
  fs.writeFileSync(envFile, 'NEORECALL_PORT=4500\nADMIN_USERNAME=admin\nADMIN_PASSWORD=secret-value\nADMIN_API_KEY=key\n');
  const env = { ADMIN_USERNAME: 'admin', ADMIN_PASSWORD: 'secret-value', ADMIN_API_KEY: 'key', OTHER: 'kept' };
  assert.deepEqual(retired.retireDashboardCredentials(envFile, env),
    { removed: retired.RETIRED_ADMIN_ENV_KEYS, ignored: [], error: null });
  assert.equal(fs.readFileSync(envFile, 'utf8'), 'NEORECALL_PORT=4500\n');
  assert.deepEqual(env, { OTHER: 'kept' });
  // Set by the deployment rather than the file: reported, not editable here.
  assert.deepEqual(retired.retireDashboardCredentials(envFile, { ADMIN_API_KEY: 'key' }),
    { removed: [], ignored: ['ADMIN_API_KEY'], error: null });
  assert.deepEqual(retired.withoutRetiredCredentials({ ADMIN_API_KEY: 'key', PATH: '/bin' }), { PATH: '/bin' });
});

test('an env file that cannot be edited is reported, never fatal, and a link is left a link', () => {
  const target = path.join(process.env.NEORECALL_HOME, 'linked-target.env');
  const link = path.join(process.env.NEORECALL_HOME, 'linked.env');
  fs.writeFileSync(target, 'ADMIN_API_KEY=key\n');
  fs.symlinkSync(target, link);
  const linked = retired.retireDashboardCredentials(link, { ADMIN_API_KEY: 'key' });
  assert.deepEqual(linked.removed, []);
  assert.deepEqual(linked.ignored, ['ADMIN_API_KEY']);
  assert.match(linked.error, /symbolic link/);
  assert.equal(fs.lstatSync(link).isSymbolicLink(), true);

  const directory = fs.mkdtempSync(path.join(process.env.NEORECALL_HOME, 'readonly-'));
  const readonly = path.join(directory, '.env');
  fs.writeFileSync(readonly, 'ADMIN_PASSWORD=secret-value\n');
  fs.chmodSync(directory, 0o500);
  try {
    const result = retired.retireDashboardCredentials(readonly, {});
    assert.deepEqual(result.removed, []);
    assert.deepEqual(result.ignored, ['ADMIN_PASSWORD']);
    assert.ok(result.error);
    assert.equal(fs.readFileSync(readonly, 'utf8'), 'ADMIN_PASSWORD=secret-value\n');
  } finally {
    fs.chmodSync(directory, 0o700);
  }
});

test('the old dashboard address sends people to the app, and its API says where it went', async () => {
  const response = await request(app).get('/admin/login.html').expect(302);
  assert.equal(response.headers.location, '/app/');
  const api = await request(app).get('/admin/api/v1/provider-settings').set(bearer(owner.token)).expect(410);
  assert.equal(api.body.error.code, 'ADMIN_API_MOVED');
  await request(app).post('/admin/api/v1/login').send({ username: 'admin', password: 'x' }).expect(410);
});
