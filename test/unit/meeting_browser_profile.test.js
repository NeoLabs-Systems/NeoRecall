'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const Database = require('better-sqlite3');

const WINDOWS_TO_UNIX_EPOCH_MS = 11644473600000;
const chromeTimestamp = (dateMs) => (dateMs + WINDOWS_TO_UNIX_EPOCH_MS) * 1000;

function withTemporaryHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-profile-test-'));
  process.env.NEORECALL_HOME = home;
  return home;
}

// A stand-in for the parts of a Chrome profile the sign-in check reads. The
// column names mirror Chrome's cookie schema, which is what the reader depends
// on — the live shape is verified separately against a real browser.
function writeProfile(dir, { cookies = [], preferences = {} } = {}) {
  fs.mkdirSync(path.join(dir, 'Default'), { recursive: true });
  const database = new Database(path.join(dir, 'Default', 'Cookies'));
  database.exec('CREATE TABLE cookies (host_key TEXT, name TEXT, encrypted_value BLOB, expires_utc INTEGER)');
  const insert = database.prepare('INSERT INTO cookies (host_key, name, encrypted_value, expires_utc) VALUES (?, ?, ?, ?)');
  for (const cookie of cookies) insert.run(cookie.host, cookie.name, Buffer.from('secret'), cookie.expiresUtc ?? 0);
  database.close();
  fs.writeFileSync(path.join(dir, 'Default', 'Preferences'), JSON.stringify(preferences));
}

test('the cookie index exposes hosts and names but never cookie values', (t) => {
  const home = withTemporaryHome();
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const profileStore = require('../../server/services/sources/meeting_bot/browser_profile');

  const dir = profileStore.ensureProfileDir('user-a');
  const expiry = Date.UTC(2030, 0, 1);
  writeProfile(dir, {
    cookies: [
      { host: '.google.com', name: 'SID', expiresUtc: chromeTimestamp(expiry) },
      { host: 'accounts.google.com', name: '__Host-GAPS', expiresUtc: 0 },
    ],
  });

  const cookies = profileStore.readCookieIndex('user-a');
  assert.deepEqual(cookies, [
    { host: '.google.com', name: 'SID', expiresAt: new Date(expiry).toISOString() },
    { host: 'accounts.google.com', name: '__Host-GAPS', expiresAt: null },
  ]);
  assert.ok(cookies.every((cookie) => !('value' in cookie) && !('encrypted_value' in cookie)));
});

test('profiles are isolated per user and cannot escape the profile root', (t) => {
  const home = withTemporaryHome();
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const profileStore = require('../../server/services/sources/meeting_bot/browser_profile');

  const root = profileStore.profileRoot();
  assert.notEqual(profileStore.profileDir('user-a'), profileStore.profileDir('user-b'));
  for (const hostile of ['../../etc', '/etc/passwd', 'a/../../b']) {
    assert.equal(path.dirname(profileStore.profileDir(hostile)), root);
  }
  assert.throws(() => profileStore.profileDir(''), /user id is required/);
});

test('a session clone carries the login but not caches or instance locks', async (t) => {
  const home = withTemporaryHome();
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const profileStore = require('../../server/services/sources/meeting_bot/browser_profile');

  const dir = profileStore.ensureProfileDir('user-a');
  writeProfile(dir, {
    cookies: [{ host: '.google.com', name: 'SID', expiresUtc: chromeTimestamp(Date.UTC(2030, 0, 1)) }],
    // Chrome that was killed leaves this behind; the clone must not inherit it
    // or the next start opens a "restore pages?" bubble over the join flow.
    preferences: { profile: { exit_type: 'Crashed', exited_cleanly: false } },
  });
  fs.mkdirSync(path.join(dir, 'Default', 'Cache', 'Cache_Data'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'Default', 'Cache', 'Cache_Data', 'blob'), 'x'.repeat(1024));
  fs.writeFileSync(path.join(dir, 'SingletonLock'), 'locked');

  const checkout = await profileStore.checkoutForSession('user-a');
  t.after(() => checkout.dispose());

  assert.equal(checkout.signedIn, true);
  assert.notEqual(checkout.dir, dir);
  assert.deepEqual(profileStore.readCookieIndexIn(checkout.dir).map((cookie) => cookie.name), ['SID']);
  assert.equal(fs.existsSync(path.join(checkout.dir, 'Default', 'Cache')), false);
  assert.equal(fs.existsSync(path.join(checkout.dir, 'SingletonLock')), false);

  const preferences = JSON.parse(fs.readFileSync(path.join(checkout.dir, 'Default', 'Preferences'), 'utf8'));
  assert.equal(preferences.profile.exit_type, 'Normal');
  assert.equal(preferences.profile.exited_cleanly, true);

  // The original is untouched: a bot must never be able to damage the login.
  const original = JSON.parse(fs.readFileSync(path.join(dir, 'Default', 'Preferences'), 'utf8'));
  assert.equal(original.profile.exit_type, 'Crashed');

  await checkout.dispose();
  assert.equal(fs.existsSync(checkout.dir), false);
});

test('a user without a connected account gets no profile and joins anonymously', async (t) => {
  const home = withTemporaryHome();
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const profileStore = require('../../server/services/sources/meeting_bot/browser_profile');

  const checkout = await profileStore.checkoutForSession('never-signed-in');
  assert.deepEqual({ dir: checkout.dir, signedIn: checkout.signedIn }, { dir: null, signedIn: false });
  await checkout.dispose();
});

test('signing out removes the profile and its metadata', (t) => {
  const home = withTemporaryHome();
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const profileStore = require('../../server/services/sources/meeting_bot/browser_profile');

  const dir = profileStore.ensureProfileDir('user-a');
  writeProfile(dir);
  profileStore.writeMetadata('user-a', { accounts: { google: { connectedAt: '2026-07-31T00:00:00.000Z' } } });
  assert.equal(profileStore.hasProfile('user-a'), true);

  profileStore.removeProfile('user-a');
  assert.equal(profileStore.hasProfile('user-a'), false);
  assert.equal(fs.existsSync(profileStore.metadataFile('user-a')), false);
  assert.deepEqual(profileStore.readMetadata('user-a'), { accounts: {} });
});
