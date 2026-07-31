'use strict';

// Persistent Chrome profiles for the meeting bots.
//
// Anonymous guests are refused outright by a large share of real meetings
// (Google Meet in particular blocks not-signed-in participants whenever the
// host restricts access, and Zoom/Teams do the same for internal meetings).
// The fix that needs no per-service API key is the one a human uses: sign the
// bot's browser in once, then reuse that browser session for every join.
//
// The master profile is written only by the interactive sign-in window
// (see meeting_account_service). Every join gets a disposable CLONE of it, so
// concurrent joins cannot fight over Chrome's single-instance lock and a
// crashed bot can never corrupt the signed-in state.

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { paths, ensurePrivateDirectory } = require('../../../../runtime/paths');

// Directory names never worth copying into a session clone: caches (large and
// rebuildable) and Chrome's single-instance guards, which would make the clone
// look like a profile another Chrome already owns.
const SKIPPED_ENTRIES = new Set([
  'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache', 'DawnCache',
  'DawnGraphiteCache', 'DawnWebGPUCache', 'CacheStorage', 'Service Worker',
  'Crashpad', 'component_crx_cache', 'optimization_guide_model_store',
  'SingletonLock', 'SingletonSocket', 'SingletonCookie', 'RunningChromeVersion',
]);

function profileRoot() {
  return path.join(paths().home, 'meeting_profiles');
}

// Profiles are addressed by a hash of the user id rather than the id itself:
// the value becomes a filesystem path, and hashing removes any possibility of
// a crafted id escaping the profile root.
function profileKey(userId) {
  const id = String(userId || '').trim();
  if (!id) throw new Error('A user id is required to resolve a meeting browser profile.');
  return crypto.createHash('sha256').update(id).digest('hex').slice(0, 32);
}

function profileDir(userId) {
  return path.join(profileRoot(), profileKey(userId));
}

function metadataFile(userId) {
  return path.join(profileRoot(), `${profileKey(userId)}.json`);
}

function hasProfile(userId) {
  return fs.existsSync(path.join(profileDir(userId), 'Default'));
}

function ensureProfileDir(userId) {
  const dir = profileDir(userId);
  ensurePrivateDirectory(profileRoot());
  ensurePrivateDirectory(dir);
  return dir;
}

function readMetadata(userId) {
  try {
    return JSON.parse(fs.readFileSync(metadataFile(userId), 'utf8'));
  } catch (error) {
    return { accounts: {} };
  }
}

function writeMetadata(userId, metadata) {
  ensurePrivateDirectory(profileRoot());
  fs.writeFileSync(metadataFile(userId), JSON.stringify(metadata, null, 2), { mode: 0o600 });
  return metadata;
}

function removeProfile(userId) {
  fs.rmSync(profileDir(userId), { recursive: true, force: true });
  fs.rmSync(metadataFile(userId), { force: true });
}

// Chrome that was killed (as the bot does at the end of a call) leaves
// exit_type="Crashed" behind, and the next start of that profile shows a
// "Restore pages?" bubble that steals focus from the join flow. The clone is
// throwaway, so mark it as cleanly exited before Chrome reads it.
function markCleanExit(dir) {
  const preferences = path.join(dir, 'Default', 'Preferences');
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(preferences, 'utf8'));
  } catch (error) {
    return false;
  }
  parsed.profile = { ...parsed.profile, exit_type: 'Normal', exited_cleanly: true };
  try {
    fs.writeFileSync(preferences, JSON.stringify(parsed));
    return true;
  } catch (error) {
    return false;
  }
}

// Chrome keeps cookies in a SQLite file whose `host_key` and `name` columns are
// plaintext — only the value is encrypted. That is all a sign-in check needs, so
// the profile can be inspected by reading a file instead of starting a browser.
const COOKIE_FILES = [
  path.join('Default', 'Network', 'Cookies'), // Chrome 96+
  path.join('Default', 'Cookies'),            // older layouts
];
// Chrome timestamps count microseconds from 1601-01-01; 0 marks a session cookie.
const WINDOWS_TO_UNIX_EPOCH_MS = 11644473600000;

function cookieFileIn(dir) {
  return COOKIE_FILES.map((relative) => path.join(dir, relative)).find((file) => fs.existsSync(file)) || null;
}

function cookieFile(userId) {
  return cookieFileIn(profileDir(userId));
}

// [{ host, name, expiresAt }] for the profile — never any cookie values.
function readCookieIndex(userId) {
  return readCookieIndexIn(profileDir(userId));
}

function readCookieIndexIn(dir) {
  const file = cookieFileIn(dir);
  if (!file) return [];
  const Database = require('better-sqlite3');
  let database;
  try {
    database = new Database(file, { readonly: true, fileMustExist: true });
    return database.prepare('SELECT host_key AS host, name, expires_utc AS expiresUtc FROM cookies').all().map((row) => ({
      host: row.host,
      name: row.name,
      expiresAt: row.expiresUtc ? new Date(row.expiresUtc / 1000 - WINDOWS_TO_UNIX_EPOCH_MS).toISOString() : null,
    }));
  } catch (error) {
    // A browser holding the profile open, or a schema change, must not turn into
    // a hard failure: the caller reports "unknown" rather than "not signed in".
    throw new Error(`Could not read the browser profile's cookies: ${error.message}`);
  } finally {
    try { if (database) database.close(); } catch (e) { /* already closed */ }
  }
}

// Best-effort identity: Chrome records the signed-in Google account in the
// profile preferences. Returns [] when it does not (e.g. Zoom/Microsoft, or web
// sign-in without Chrome identity) — the connection is still valid, just unnamed.
function readAccountEmails(userId) {
  return readAccountEmailsIn(profileDir(userId));
}

function readAccountEmailsIn(dir) {
  let preferences;
  try {
    preferences = JSON.parse(fs.readFileSync(path.join(dir, 'Default', 'Preferences'), 'utf8'));
  } catch (error) {
    return [];
  }
  const accounts = Array.isArray(preferences.account_info) ? preferences.account_info : [];
  return accounts.map((account) => account && account.email).filter(Boolean);
}

// A disposable copy of the user's signed-in profile for one meeting.
// Returns { dir: null } when the user has not connected an account — the bot
// then joins anonymously, which still works for meetings that allow guests.
async function checkoutForSession(userId) {
  if (!userId || !hasProfile(userId)) {
    return { dir: null, signedIn: false, dispose: async () => {} };
  }

  const source = profileDir(userId);
  const target = path.join(os.tmpdir(), `neorecall-meet-profile-${crypto.randomUUID()}`);
  try {
    await fsp.cp(source, target, {
      recursive: true,
      force: true,
      dereference: false,
      // Copying a profile Chrome holds open can race on individual files; the
      // session state we need (cookies, tokens) is written at sign-in time and
      // stable afterwards, so a partial cache copy is harmless.
      filter: (entry) => !SKIPPED_ENTRIES.has(path.basename(entry)),
    });
  } catch (error) {
    await fsp.rm(target, { recursive: true, force: true }).catch(() => {});
    throw new Error(`Could not prepare the signed-in browser profile: ${error.message}`);
  }
  markCleanExit(target);

  return {
    dir: target,
    signedIn: true,
    dispose: async () => { await fsp.rm(target, { recursive: true, force: true }).catch(() => {}); },
  };
}

module.exports = {
  profileRoot,
  profileDir,
  metadataFile,
  hasProfile,
  ensureProfileDir,
  readMetadata,
  writeMetadata,
  removeProfile,
  markCleanExit,
  checkoutForSession,
  cookieFile,
  cookieFileIn,
  readCookieIndex,
  readCookieIndexIn,
  readAccountEmails,
  readAccountEmailsIn,
  SKIPPED_ENTRIES,
};
