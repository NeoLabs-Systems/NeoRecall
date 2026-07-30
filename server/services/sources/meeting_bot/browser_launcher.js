'use strict';

const { spawn } = require('node:child_process');
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright-extra');
const stealthPlugin = require('puppeteer-extra-plugin-stealth')();
// These two evasions interfere with Google Meet's media/iframe handling and, on
// real Chrome, contradict genuine values — disable them (as screenapp does).
stealthPlugin.enabledEvasions.delete('iframe.contentWindow');
stealthPlugin.enabledEvasions.delete('media.codecs');
chromium.use(stealthPlugin);

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
async function launchViaCdpSpawn(chromePath, opts) {
  const port = await freePort();
  const userDataDir = path.join(os.tmpdir(), `neorecall-meet-${crypto.randomUUID()}`);
  const child = spawn(chromePath, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    ...baseArgs(opts),
    'about:blank',
  ], { stdio: 'ignore' });
  child.on('error', () => {});

  let browser;
  try {
    const cdpUrl = await waitForCdp(port);
    browser = await chromium.connectOverCDP(cdpUrl);
  } catch (err) {
    try { child.kill('SIGKILL'); } catch (e) {}
    fs.rm(userDataDir, { recursive: true, force: true }, () => {});
    throw err;
  }

  const { context, page } = await attachContextPage(browser);
  const dispose = async () => {
    try { await browser.close(); } catch (e) {}
    try { child.kill('SIGKILL'); } catch (e) {}
    fs.rm(userDataDir, { recursive: true, force: true }, () => {});
  };
  return { browser, context, page, dispose, mode: `cdp-spawn (${path.basename(chromePath)})` };
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
// the automation fingerprint; we strip what we can. Prefers real Chrome channel,
// falls back to bundled Chromium.
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

  let browser;
  try {
    browser = await chromium.launch(channel ? { ...launchOptions, channel } : launchOptions);
  } catch (err) {
    if (!channel) throw err;
    browser = await chromium.launch(launchOptions); // bundled Chromium fallback
  }
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, ignoreHTTPSErrors: true });
  const page = await context.newPage();
  const dispose = async () => { try { await browser.close(); } catch (e) {} };
  return { browser, context, page, dispose, mode: channel ? `direct (${channel})` : 'direct (bundled)' };
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

module.exports = { createMeetingBrowser, resolveChromePath };
