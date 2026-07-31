'use strict';

// Connects the meeting bots to a real account without any per-service API key.
//
// The user signs in once, by hand, in an ordinary Chrome window that NeoRecall
// opens on the machine running the server. NeoRecall never sees the password:
// it is typed into the provider's own sign-in page, and all NeoRecall keeps is
// the browser profile Chrome writes. Later joins reuse that profile, so the bot
// arrives as a signed-in participant instead of an anonymous guest — which is
// what most meetings actually require.

const profileStore = require('./browser_profile');

// The launcher pulls in Playwright, which a trimmed deployment may not have.
// Loading it lazily keeps that an unavailable *feature* rather than a server
// that will not boot — the same reason the source registry loads drivers lazily.
function launcher() {
  try {
    return require('./browser_launcher');
  } catch (error) {
    console.error('[MeetingAccount] Browser support is unavailable:', error.message);
    return null;
  }
}

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

// One open sign-in window per user: Chrome refuses a second instance on the same
// profile directory, and two windows would race on the same cookie store.
const openSignInWindows = new Map();

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

const meetingAccountService = {
  PROVIDERS,
  matchProviders,

  // Everything the UI needs to render the "Meeting account" panel.
  getStatus(userId) {
    const browser = launcher();
    const chromePath = browser ? browser.resolveChromePath() : null;
    const display = browser ? browser.hasDisplay() : false;
    const inspection = inspectProfile(userId);
    const metadata = profileStore.readMetadata(userId);
    const pending = openSignInWindows.get(userId) || null;

    return {
      chromeAvailable: Boolean(chromePath),
      displayAvailable: display,
      canSignIn: Boolean(chromePath) && display,
      // Why sign-in is unavailable, so the UI can say something useful instead
      // of just greying a button out.
      blockedReason: !browser
        ? 'no-browser-support'
        : (chromePath ? (display ? null : 'no-display') : 'no-chrome'),
      profileExists: profileStore.hasProfile(userId),
      profilePath: profileStore.profileDir(userId),
      warning: inspection.warning,
      accountEmails: inspection.emails,
      signInPending: pending ? { provider: pending.provider, startedAt: pending.startedAt } : null,
      providers: Object.values(PROVIDERS).map((provider) => ({
        id: provider.id,
        label: provider.label,
        platforms: provider.platforms,
        connected: inspection.connected[provider.id] ?? false,
        connectedAt: (metadata.accounts && metadata.accounts[provider.id] && metadata.accounts[provider.id].connectedAt) || null,
      })),
    };
  },

  // Opens the visible sign-in window on the server host. Returns once the window
  // has been spawned — the user then signs in at their own pace and the UI calls
  // completeSignIn().
  startSignIn(userId, providerId) {
    const provider = requireProvider(providerId);
    const browser = launcher();
    if (!browser) {
      throw new Error('This build cannot drive a browser, so meeting accounts are unavailable. Install the Playwright dependency and restart NeoRecall.');
    }
    const chromePath = browser.resolveChromePath();
    if (!chromePath) {
      throw new Error('Google Chrome was not found on the machine running NeoRecall. Install it (or run "npx playwright install chrome") and try again.');
    }
    if (!browser.hasDisplay()) {
      throw new Error('The machine running NeoRecall has no display, so the sign-in window cannot be shown. Sign in on a desktop machine and copy the profile directory over, or run the server on a machine with a screen.');
    }
    if (openSignInWindows.has(userId)) {
      throw new Error('A sign-in window is already open. Finish it (or cancel it) before starting another.');
    }

    const userDataDir = profileStore.ensureProfileDir(userId);
    const child = browser.spawnSignInWindow({ chromePath, userDataDir, url: provider.signInUrl });
    const entry = { child, provider: provider.id, startedAt: new Date().toISOString() };
    openSignInWindows.set(userId, entry);
    child.on('exit', () => {
      if (openSignInWindows.get(userId) === entry) openSignInWindows.delete(userId);
    });

    return { provider: provider.id, label: provider.label, signInUrl: provider.signInUrl };
  },

  // Closes the sign-in window (cleanly, so Chrome flushes its cookie store) and
  // reports what the profile ended up holding.
  async completeSignIn(userId) {
    await this.closeSignInWindow(userId);
    const status = this.getStatus(userId);

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

    return this.getStatus(userId);
  },

  // SIGTERM first: Chrome only writes pending cookies to disk on a clean exit,
  // and a killed browser can lose the session the user just created.
  async closeSignInWindow(userId, { graceMs = 10000 } = {}) {
    const entry = openSignInWindows.get(userId);
    if (!entry) return false;
    openSignInWindows.delete(userId);
    const { child } = entry;
    if (child.exitCode !== null || child.signalCode !== null) return true;

    await new Promise((resolve) => {
      const finish = () => { clearTimeout(timer); resolve(); };
      const timer = setTimeout(() => {
        try { child.kill('SIGKILL'); } catch (error) { /* already gone */ }
        resolve();
      }, graceMs);
      child.once('exit', finish);
      try { child.kill('SIGTERM'); } catch (error) { finish(); }
    });
    return true;
  },

  async signOut(userId) {
    await this.closeSignInWindow(userId);
    profileStore.removeProfile(userId);
    return this.getStatus(userId);
  },

  // Used by the bots to explain a refusal in terms of what is actually connected.
  describeConnection(userId) {
    const inspection = inspectProfile(userId);
    const emails = inspection.emails;
    return {
      signedIn: Object.values(inspection.connected).some(Boolean),
      connected: inspection.connected,
      identity: emails.length ? emails.join(', ') : null,
    };
  },
};

module.exports = meetingAccountService;
