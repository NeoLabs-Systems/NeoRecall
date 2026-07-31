'use strict';

const { spawn } = require('node:child_process');
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const { chromium: stealthChromium } = require('playwright-extra');
const stealthPlugin = require('puppeteer-extra-plugin-stealth')();
// These two evasions interfere with Google Meet's media/iframe handling and, on
// real Chrome, contradict genuine values — disable them (as screenapp does).
stealthPlugin.enabledEvasions.delete('iframe.contentWindow');
stealthPlugin.enabledEvasions.delete('media.codecs');
stealthChromium.use(stealthPlugin);

// Well-known real-Chrome install locations per platform. `neorecall setup` runs
// `playwright install chrome`, which installs branded Google Chrome to these.
const CHROME_PATHS = {
  darwin: [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    path.join(os.homedir(), 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
  ],
  win32: [
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    path.join(os.homedir(), 'AppData\\Local\\Google\\Chrome\\Application\\chrome.exe'),
  ],
  linux: [
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
    '/opt/google/chrome/chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ],
};

function resolveChromePath() {
  const override = process.env.MEETING_BOT_CHROME_PATH;
  if (override && fs.existsSync(override)) return override;
  for (const candidate of CHROME_PATHS[process.platform] || []) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// Whether this host can put a real window on a screen. Needed for the
// interactive sign-in window: a headless box can run the bots, but nobody can
// type a password into a browser it cannot display.
function hasDisplay() {
  if (process.platform === 'darwin' || process.platform === 'win32') return true;
  return Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// Poll the DevTools endpoint until Chrome is ready to accept a CDP connection.
function waitForCdp(port, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  const url = `http://127.0.0.1:${port}/json/version`;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = http.get(url, (res) => {
        res.resume();
        if (res.statusCode === 200) return resolve(`http://127.0.0.1:${port}`);
        retry();
      });
      req.on('error', retry);
      req.setTimeout(1500, () => req.destroy());
    };
    const retry = () => {
      if (Date.now() > deadline) return reject(new Error('Chrome DevTools endpoint did not come up in time'));
      setTimeout(attempt, 250);
    };
    attempt();
  });
}

// Base flags shared by every launch strategy. `--headless=new` is only added for
// the no-display fallback (it's more detectable at Google's join step).
function baseArgs({ extraArgs = [], headlessFallback = false } = {}) {
  const args = [
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-default-apps',
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--disable-dev-shm-usage',
    '--window-size=1280,800',
    '--window-position=-32000,-32000', // off-screen: headful but invisible to the user
    '--auto-accept-this-tab-capture',
    '--autoplay-policy=no-user-gesture-required',
    ...extraArgs,
  ];
  if (headlessFallback) args.push('--headless=new');
  return args;
}

async function attachContextPage(browser) {
  const context = browser.contexts()[0] || (await browser.newContext());
  const page = context.pages().find((p) => !p.isClosed()) || (await context.newPage());
  return { context, page };
}

// STRATEGY 1 — spawn real Chrome as a normal OS process, then attach over CDP.
// Because Playwright never *launches* it, the browser carries none of the
// launch-time automation fingerprint (no --enable-automation, navigator.webdriver
// stays false) — the least-detectable configuration and screenapp's prod default.
// `opts.userDataDir` (a throwaway clone of the signed-in profile) makes the bot
// join as that account instead of as an anonymous guest.
async function launchViaCdpSpawn(chromePath, opts) {
  const port = await freePort();
  const borrowedProfile = Boolean(opts && opts.userDataDir);
  const userDataDir = borrowedProfile
    ? opts.userDataDir
    : path.join(os.tmpdir(), `neorecall-meet-${crypto.randomUUID()}`);
  const child = spawn(chromePath, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    ...baseArgs(opts),
    'about:blank',
  ], { stdio: 'ignore' });
  child.on('error', () => {});

  // Only the temp profile we created here is ours to delete; a borrowed clone
  // belongs to the caller (AbstractBot disposes it with the session).
  const discardProfile = () => {
    if (!borrowedProfile) fs.rm(userDataDir, { recursive: true, force: true }, () => {});
  };

  let browser;
  try {
    const cdpUrl = await waitForCdp(port);
    browser = await chromium.connectOverCDP(cdpUrl);
  } catch (err) {
    try { child.kill('SIGKILL'); } catch (e) {}
    discardProfile();
    throw err;
  }

  const { context, page } = await attachContextPage(browser);
  const dispose = async () => {
    try { await browser.close(); } catch (e) {}
    try { child.kill('SIGKILL'); } catch (e) {}
    discardProfile();
  };
  return {
    browser, context, page, dispose,
    mode: `cdp-spawn (${path.basename(chromePath)}${borrowedProfile ? ', signed-in profile' : ''})`,
  };
}

// STRATEGY 2 — connect to an already-running external Chrome (advanced/prod:
// a sidecar the operator manages), via MEETING_BOT_CDP_URL.
async function launchViaCdpConnect(cdpUrl) {
  const browser = await chromium.connectOverCDP(cdpUrl);
  const { context, page } = await attachContextPage(browser);
  const dispose = async () => { try { await browser.close(); } catch (e) {} };
  return { browser, context, page, dispose, mode: `cdp-connect (${cdpUrl})` };
}

// STRATEGY 3 — Playwright launches the browser directly. Simplest, but carries
// the automation fingerprint; we strip what we can. Prefers real Chrome, falls
// back to bundled Chromium.
//
// The stealth plugin is applied to bundled Chromium only. Its evasions exist to
// make *Chromium* look like Chrome; running them on genuine Chrome overwrites
// already-correct values and introduces the inconsistencies detectors look for.
async function launchDirect(opts) {
  const launchOptions = {
    headless: false,
    ignoreDefaultArgs: ['--enable-automation', '--mute-audio'],
    args: baseArgs(opts),
    handleSIGINT: false,
    handleSIGTERM: false,
    handleSIGHUP: false,
  };
  if (process.env.MEETING_BOT_CHROME_PATH) launchOptions.executablePath = process.env.MEETING_BOT_CHROME_PATH;
  const channel = launchOptions.executablePath ? undefined : (process.env.MEETING_BOT_CHROME_CHANNEL || 'chrome');
  const userDataDir = opts && opts.userDataDir;

  // Persistent profile: launchPersistentContext is the only launch API that
  // takes a user-data-dir, so the signed-in session survives this route too.
  if (userDataDir) {
    const context = await chromium.launchPersistentContext(userDataDir, {
      ...launchOptions,
      ...(channel ? { channel } : {}),
      viewport: null,
      ignoreHTTPSErrors: true,
    });
    const page = context.pages().find((p) => !p.isClosed()) || (await context.newPage());
    const dispose = async () => { try { await context.close(); } catch (e) {} };
    return { browser: context.browser(), context, page, dispose, mode: 'direct (signed-in profile)' };
  }

  let browser;
  let usedRealChrome = Boolean(channel || launchOptions.executablePath);
  try {
    browser = await chromium.launch(channel ? { ...launchOptions, channel } : launchOptions);
  } catch (err) {
    if (!channel) throw err;
    usedRealChrome = false;
    browser = await stealthChromium.launch(launchOptions); // bundled Chromium fallback
  }
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, ignoreHTTPSErrors: true });
  const page = await context.newPage();
  const dispose = async () => { try { await browser.close(); } catch (e) {} };
  return { browser, context, page, dispose, mode: usedRealChrome ? `direct (${channel || 'chrome path'})` : 'direct (bundled + stealth)' };
}

// Create the meeting browser using the least-detectable strategy available.
// Order: external CDP → spawn-real-Chrome+CDP → direct launch. Returns
// { context, page, dispose, mode }.
async function createMeetingBrowser(opts = {}) {
  if (process.env.MEETING_BOT_CDP_URL) {
    return launchViaCdpConnect(process.env.MEETING_BOT_CDP_URL);
  }
  if (process.env.MEETING_BOT_LAUNCH_MODE !== 'direct') {
    const chromePath = resolveChromePath();
    if (chromePath) {
      try {
        return await launchViaCdpSpawn(chromePath, opts);
      } catch (err) {
        console.warn(`[MeetingBot] CDP-spawn launch failed (${err.message}); falling back to direct launch.`);
      }
    } else {
      console.warn('[MeetingBot] Real Chrome not found for CDP-spawn; run "npx playwright install chrome". Falling back to direct launch.');
    }
  }
  return launchDirect(opts);
}

// A plain, visible Chrome window for the one-time account sign-in.
//
// Deliberately *not* automated: no remote-debugging port, no Playwright, no
// stealth. Google refuses sign-in ("This browser or app may not be secure") in
// a browser it can see is being driven, so the user signs in in an ordinary
// window and NeoRecall only reads the resulting profile afterwards. The
// password is typed into Google's own page and never passes through NeoRecall.
function spawnSignInWindow({ chromePath, userDataDir, url }) {
  const child = spawn(chromePath, [
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1100,900',
    '--new-window',
    url,
  ], { stdio: 'ignore', detached: false });
  child.on('error', () => {});
  return child;
}

// Attach to a profile just long enough to inspect its cookies (sign-in check).
// Off-screen and short-lived; the caller must close it via dispose().
async function openProfileForInspection(chromePath, userDataDir) {
  return launchViaCdpSpawn(chromePath, { userDataDir, extraArgs: ['--disable-extensions'] });
}

module.exports = {
  createMeetingBrowser,
  resolveChromePath,
  hasDisplay,
  spawnSignInWindow,
  openProfileForInspection,
};
