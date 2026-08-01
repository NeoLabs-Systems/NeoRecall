'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const accounts = require('../../server/services/sources/meeting_bot/meeting_account_service');
const GoogleMeetBot = require('../../server/services/sources/meeting_bot/GoogleMeetBot');
const { JoinError } = require('../../server/services/sources/meeting_bot/meet_helpers');

const NOW = Date.UTC(2026, 6, 31);
const future = new Date(Date.UTC(2027, 0, 1)).toISOString();
const past = new Date(Date.UTC(2025, 0, 1)).toISOString();

test('a live provider cookie counts as a connected account', () => {
  const connected = accounts.matchProviders([
    { host: '.google.com', name: 'SID', expiresAt: future },
    { host: '.zoom.us', name: 'zm_aid', expiresAt: null },
  ], NOW);
  assert.deepEqual(connected, { google: true, microsoft: false, zoom: true });
});

test('expired or foreign-host cookies do not count as connected', () => {
  const connected = accounts.matchProviders([
    { host: '.google.com', name: 'SID', expiresAt: past },
    // A look-alike domain must not satisfy the Google check.
    { host: '.notgoogle.com.evil.test', name: '__Secure-1PSID', expiresAt: future },
    { host: '.google.com', name: 'NID', expiresAt: future }, // present for guests too
  ], NOW);
  assert.deepEqual(connected, { google: false, microsoft: false, zoom: false });
});

test('Microsoft sessions are recognised from the login domain', () => {
  const connected = accounts.matchProviders([
    { host: '.login.microsoftonline.com', name: 'ESTSAUTHPERSISTENT', expiresAt: future },
  ], NOW);
  assert.equal(connected.microsoft, true);
});

test('an unknown provider is rejected instead of silently ignored', () => {
  assert.throws(() => accounts.beginSignIn('user-a', 'webex'), /Unknown meeting account provider/);
});

// The same refusal from Google means opposite things depending on who the bot
// is, and the two need opposite fixes — so the message has to say which one.
function refusalFor(connection) {
  const bot = new GoogleMeetBot('user-a', 'source-a', 'Meeting Notes', 'https://meet.google.com/abc-defg-hij');
  bot.connection = connection;
  return bot._refusalError('Google Meet refused the join.');
}

test('a refused anonymous join points at connecting an account', () => {
  const error = refusalFor({ signedIn: false, connected: {}, identity: null });
  assert.ok(error instanceof JoinError);
  assert.equal(error.code, 'anonymous_blocked');
  assert.match(error.message, /anonymous guest/);
  assert.match(error.message, /Meeting account/);
});

test('a refused signed-in join points at the invite, naming the account', () => {
  const error = refusalFor({ signedIn: true, connected: { google: true }, identity: 'notes@example.com' });
  assert.equal(error.code, 'not_invited');
  assert.match(error.message, /notes@example\.com/);
  assert.match(error.message, /invited people/);
});
