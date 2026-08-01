'use strict';

// Provider registry and pure cookie-matching logic for meeting accounts —
// split out from meeting_account_service.js so the interactive sign-in engine
// (signin_session.js) can update connection metadata without requiring the
// service that, in turn, starts sign-in sessions (which would be a cycle).

const profileStore = require('./browser_profile');

// Everything provider-specific lives here so adding a platform stays a data
// change. `sessionCookies` are the names Chrome writes once a durable web
// session exists; presence of any one of them means "signed in".
const PROVIDERS = {
  google: {
    id: 'google',
    label: 'Google',
    platforms: 'Google Meet',
    signInUrl: 'https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmeet.google.com%2F',
    cookieHosts: ['.google.com', 'google.com'],
    sessionCookies: ['SID', '__Secure-1PSID', '__Secure-3PSID'],
  },
  microsoft: {
    id: 'microsoft',
    label: 'Microsoft',
    platforms: 'Microsoft Teams',
    signInUrl: 'https://teams.microsoft.com/',
    cookieHosts: ['.login.microsoftonline.com', '.microsoft.com', '.live.com'],
    sessionCookies: ['ESTSAUTHPERSISTENT', 'ESTSAUTH', 'MSPAuth', 'MSPProf'],
  },
  zoom: {
    id: 'zoom',
    label: 'Zoom',
    platforms: 'Zoom',
    signInUrl: 'https://zoom.us/signin',
    cookieHosts: ['.zoom.us', 'zoom.us'],
    sessionCookies: ['zm_aid', 'zm_haid', '_zm_ssid'],
  },
};

function requireProvider(providerId) {
  const provider = PROVIDERS[providerId];
  if (!provider) {
    throw new Error(`Unknown meeting account provider "${providerId}". Supported: ${Object.keys(PROVIDERS).join(', ')}.`);
  }
  return provider;
}

function hostMatches(cookieHost, providerHosts) {
  const host = String(cookieHost || '').toLowerCase();
  return providerHosts.some((candidate) => host === candidate || host.endsWith(candidate));
}

function isLive(cookie, now) {
  return !cookie.expiresAt || Date.parse(cookie.expiresAt) > now;
}

// Which providers a cookie index proves a live session for. Pure, so the rule
// deciding "this bot can join as a real participant" is directly testable.
function matchProviders(cookies, now = Date.now()) {
  return Object.fromEntries(Object.values(PROVIDERS).map((provider) => [
    provider.id,
    cookies.some((cookie) => provider.sessionCookies.includes(cookie.name)
      && hostMatches(cookie.host, provider.cookieHosts)
      && isLive(cookie, now)),
  ]));
}

// `null` for a provider means "could not tell" (profile busy or unreadable),
// never a guess.
function inspectProfile(userId) {
  if (!profileStore.hasProfile(userId)) {
    return { readable: true, connected: matchProviders([]), emails: [], warning: null };
  }
  let cookies;
  try {
    cookies = profileStore.readCookieIndex(userId);
  } catch (error) {
    const unknown = Object.fromEntries(Object.keys(PROVIDERS).map((id) => [id, null]));
    return { readable: false, connected: unknown, emails: [], warning: error.message };
  }
  return {
    readable: true,
    connected: matchProviders(cookies),
    emails: profileStore.readAccountEmails(userId),
    warning: null,
  };
}

function getStatus(userId) {
  const inspection = inspectProfile(userId);
  const metadata = profileStore.readMetadata(userId);
  return {
    profileExists: profileStore.hasProfile(userId),
    warning: inspection.warning,
    accountEmails: inspection.emails,
    providers: Object.values(PROVIDERS).map((provider) => ({
      id: provider.id,
      label: provider.label,
      platforms: provider.platforms,
      connected: inspection.connected[provider.id] ?? false,
      connectedAt: (metadata.accounts && metadata.accounts[provider.id] && metadata.accounts[provider.id].connectedAt) || null,
    })),
  };
}

// Called once a sign-in session ends (successfully or not): re-reads what the
// profile actually holds and reconciles the "connected since" bookkeeping
// against it, so metadata always reflects the real cookie state rather than
// what the sign-in attempt merely intended.
function recordSignInResult(userId) {
  const status = getStatus(userId);
  const metadata = profileStore.readMetadata(userId);
  metadata.accounts = metadata.accounts || {};
  const connectedAt = new Date().toISOString();
  for (const provider of status.providers) {
    if (provider.connected && !metadata.accounts[provider.id]) {
      metadata.accounts[provider.id] = { connectedAt };
    } else if (!provider.connected) {
      delete metadata.accounts[provider.id];
    }
  }
  metadata.userId = userId;
  profileStore.writeMetadata(userId, metadata);
  return getStatus(userId);
}

// Used by the bots to explain a refusal in terms of what is actually connected.
function describeConnection(userId) {
  const inspection = inspectProfile(userId);
  const emails = inspection.emails;
  return {
    signedIn: Object.values(inspection.connected).some(Boolean),
    connected: inspection.connected,
    identity: emails.length ? emails.join(', ') : null,
  };
}

module.exports = {
  PROVIDERS,
  requireProvider,
  matchProviders,
  inspectProfile,
  getStatus,
  recordSignInResult,
  describeConnection,
};
