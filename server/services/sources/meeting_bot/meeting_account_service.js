'use strict';

// Connects the meeting bots to a real account without any per-service API key.
//
// Most meetings refuse anonymous guests outright, so the bot needs to join as
// a real signed-in participant. The user connects an account once; later joins
// reuse that connection. Signing in happens live, in the user's own browser,
// against an isolated per-user browser session on the server (see
// signin_session.js / signin_relay.js) — the server host itself is never
// shown or touched. NeoRecall keeps only the resulting browser profile and
// reads it for cookie names and hosts, never for the password or cookie
// values themselves.

const accountMetadata = require('./account_metadata');
const profileStore = require('./browser_profile');
const tickets = require('./signin_tickets');
const { registry } = require('./signin_session');
const { RELAY_PATH } = require('./signin_relay');

function browserSupportAvailable() {
  try {
    require('./browser_launcher');
    return true;
  } catch (error) {
    return false;
  }
}

const meetingAccountService = {
  PROVIDERS: accountMetadata.PROVIDERS,
  matchProviders: accountMetadata.matchProviders,
  describeConnection: accountMetadata.describeConnection,

  // Everything the UI needs to render the "Meeting account" panel.
  getStatus(userId) {
    const available = browserSupportAvailable();
    const status = accountMetadata.getStatus(userId);
    const active = registry.get(userId);
    return {
      ...status,
      available,
      blockedReason: available ? null : 'unavailable',
      signInPending: active ? { provider: active.provider.id, startedAt: active.startedAt } : null,
    };
  },

  // Mints a one-time ticket for the live sign-in relay. The caller (the REST
  // route) is already authenticated; the ticket carries that authorization
  // over to the WebSocket, which cannot send an Authorization header itself.
  beginSignIn(userId, providerId) {
    const provider = accountMetadata.requireProvider(providerId);
    if (!browserSupportAvailable()) {
      throw new Error('This build cannot drive a browser, so connecting an account is unavailable. Install the Playwright dependency and restart NeoRecall.');
    }
    if (registry.get(userId)) {
      throw new Error('A sign-in is already in progress. Finish or close it before starting another.');
    }
    const ticket = tickets.issue(userId, providerId);
    return { ticket, path: RELAY_PATH, provider: provider.id, label: provider.label, expiresInMs: tickets.TICKET_TTL_MS };
  },

  async signOut(userId) {
    await registry.end(userId);
    profileStore.removeProfile(userId);
    return this.getStatus(userId);
  },
};

module.exports = meetingAccountService;
