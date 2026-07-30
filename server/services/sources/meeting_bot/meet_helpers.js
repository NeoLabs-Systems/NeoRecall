'use strict';

// Platform-agnostic primitives for driving web meeting lobbies (Google Meet,
// Zoom, Teams). Kept as pure functions over a Playwright `scope` — a Page OR a
// Frame, both of which expose evaluate/locator/getByRole — so the platform bots
// share one implementation instead of duplicating selector logic.

// Click the first visible, enabled <button> whose visible text or aria-label
// includes any of `texts` (case-insensitive, so it works across locales and
// markup changes). Returns the matched text, or null if nothing was clicked.
async function clickButtonByTexts(scope, texts) {
  for (const text of texts) {
    const clicked = await scope.evaluate((needle) => {
      const btn = Array.from(document.querySelectorAll('button')).find((el) => {
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0 || el.disabled) return false;
        const label = (el.innerText || el.getAttribute('aria-label') || '').toLowerCase();
        return label.includes(needle.toLowerCase());
      });
      if (!btn) return false;
      btn.click();
      return true;
    }, text).catch(() => false);
    if (clicked) return text;
  }
  return null;
}

// First entry of `texts` present in the scope's body text, else null.
async function bodyIncludesAny(scope, texts) {
  if (!texts || texts.length === 0) return null;
  const body = await scope.evaluate(() => (document.body ? document.body.innerText : '')).catch(() => '');
  return texts.find((t) => body.includes(t)) || null;
}

// Turn off pre-join device toggles so the bot never transmits. Each toggle is
// { name, re } where `re` matches the accessible name shown while the device is
// ON (e.g. "Turn off microphone"). If it's already off the name differs and
// nothing is clicked. Returns the names actually turned off.
async function turnOffToggles(scope, toggles) {
  const turnedOff = [];
  for (const { name, re } of toggles) {
    try {
      const btn = scope.getByRole('button', { name: re }).first();
      if (await btn.isVisible({ timeout: 2000 }).catch(() => false)) {
        await btn.click().catch(() => {});
        turnedOff.push(name);
      }
    } catch (e) { /* toggle absent */ }
  }
  return turnedOff;
}

// Poll until admitted or fail with a clear reason. Admission = `admittedSelector`
// visible. Failure = the tab is redirected off `meetingHost` (kicked/denied), or
// a terminal `cannotJoinTexts` string appears. `page` drives timing; `scope`
// (defaults to page) is where elements/text are checked.
async function waitForAdmission(page, { admittedSelector, meetingHost, cannotJoinTexts = [], scope = page, timeoutMs = 120000, pollMs = 2000 }) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (admittedSelector && await scope.locator(admittedSelector).first().isVisible().catch(() => false)) return;
    if (meetingHost && !page.url().includes(meetingHost)) {
      throw new Error(`Redirected off ${meetingHost} while waiting for admission (join denied or timed out).`);
    }
    const refused = await bodyIncludesAny(scope, cannotJoinTexts);
    if (refused) throw new Error(`Join refused by the meeting ("${refused}").`);
    await page.waitForTimeout(pollMs);
  }
  throw new Error('Timed out waiting to be admitted from the lobby.');
}

// Meeting hosts and Google's heuristics flag obvious "…bot"/"notetaker" guest
// names. Strip the risky tokens (patterned on screenapp's googleMeetDisplayName)
// so the bot presents a neutral, human-plausible name.
const RISKY_NAME_PATTERNS = [
  [/\b(?:ai[\s-]*)?note[\s-]*taker\b/gi, 'Meeting Notes'],
  [/\brobots?\b/gi, 'Meeting Notes'],
  [/\bbots?\b/gi, 'Meeting Notes'],
];
function sanitizeDisplayName(name) {
  let out = String(name || '').trim();
  for (const [re, replacement] of RISKY_NAME_PATTERNS) out = out.replace(re, replacement);
  out = out.replace(/\s{2,}/g, ' ').trim();
  return out || 'Meeting Notes';
}

// Small randomized pause — light "human" pacing between steps. Not the thing
// that beats detection (real Chrome is), but cheap and harmless.
function humanPause(page, minMs = 350, maxMs = 900) {
  return page.waitForTimeout(minMs + Math.floor(Math.random() * (maxMs - minMs)));
}

// Fill a text field like a person: focus, then type character-by-character with
// a small per-key delay, instead of an instant .fill().
async function humanFill(locator, text) {
  await locator.click().catch(() => {});
  await locator.pressSequentially(text, { delay: 60 + Math.floor(Math.random() * 90) });
}

module.exports = { clickButtonByTexts, bodyIncludesAny, turnOffToggles, waitForAdmission, sanitizeDisplayName, humanPause, humanFill };
