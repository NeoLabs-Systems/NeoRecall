'use strict';

// Drives the interactive account sign-in entirely from the user's own device.
//
// The browser that renders the provider's sign-in page runs isolated per user
// on the server, headless — it never opens a window anywhere, so it needs no
// access to (and gives no access to) the machine running NeoRecall. What the
// user actually sees and types into comes from a live CDP screencast relayed
// over a WebSocket to their own browser tab; their clicks and keystrokes are
// relayed back the same way. NeoRecall's server is a relay for pixels and
// input events, never a party that can read the password itself.
//
// One session per user: a second sign-in for the same user would either fight
// the first over the same profile directory or silently orphan it, so it is
// refused instead (see SignInRegistry.begin).

const EventEmitter = require('node:events');
const profileStore = require('./browser_profile');
const accountMetadata = require('./account_metadata');
const { getConfig } = require('../../../config');

// A screencast frame a client never acknowledges (dropped connection, dead
// tab) must not stall the whole session, and an abandoned session must not
// hold a headless Chrome process open forever burning CPU/memory.
const FRAME_ACK_TIMEOUT_MS = 5000;

// Buttons available to Input.dispatchMouseEvent; only 'left' is ever sent from
// the client today, but naming the mapping keeps the wire format extensible.
const MOUSE_BUTTONS = new Set(['left', 'middle', 'right']);

// Keys the client can send by name instead of a literal character (Backspace,
// Enter, Tab, Escape, arrows — the keys a text-diff/insertText approach cannot
// express). windowsVirtualKeyCode values are what CDP's Input domain expects.
const NAMED_KEYS = {
  Backspace: { keyCode: 8, code: 'Backspace' },
  Tab: { keyCode: 9, code: 'Tab' },
  Enter: { keyCode: 13, code: 'Enter' },
  Escape: { keyCode: 27, code: 'Escape' },
  ArrowLeft: { keyCode: 37, code: 'ArrowLeft' },
  ArrowUp: { keyCode: 38, code: 'ArrowUp' },
  ArrowRight: { keyCode: 39, code: 'ArrowRight' },
  ArrowDown: { keyCode: 40, code: 'ArrowDown' },
  Delete: { keyCode: 46, code: 'Delete' },
};

function launcher() {
  try {
    return require('./browser_launcher');
  } catch (error) {
    return null;
  }
}

class SignInSession extends EventEmitter {
  constructor(userId, provider) {
    super();
    this.userId = userId;
    this.provider = provider;
    this.startedAt = new Date().toISOString();
    this._ended = false;
    this._handle = null;
    this._idleTimer = null;
  }

  async start() {
    const browser = launcher();
    if (!browser) throw new Error('This build cannot drive a browser, so connecting an account is unavailable.');
    const userDataDir = profileStore.ensureProfileDir(this.userId);
    this._handle = await browser.launchSignInBrowser(userDataDir);
    const { cdp, page } = this._handle;

    cdp.on('Page.screencastFrame', (event) => this._onFrame(event));
    await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 65, maxWidth: 1024, maxHeight: 768 });
    this._resetIdleTimer();

    try {
      await page.goto(this.provider.signInUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    } catch (error) {
      // A slow or unreachable sign-in page is not fatal to the session — the
      // user can still see the tab and navigate/retry from the stream itself.
      this.emit('log', `Initial navigation to ${this.provider.label} did not finish: ${error.message}`);
    }
  }

  _resetIdleTimer() {
    clearTimeout(this._idleTimer);
    this._idleTimer = setTimeout(() => {
      this.emit('timeout');
      this.finish().catch(() => {});
    }, getConfig().meetingSignInIdleTimeoutMs);
    this._idleTimer.unref();
  }

  async _onFrame(event) {
    this.emit('frame', { data: event.data, metadata: event.metadata });
    try {
      await Promise.race([
        this._handle.cdp.send('Page.screencastFrameAck', { sessionId: event.sessionId }),
        new Promise((_, reject) => setTimeout(() => reject(new Error('ack timeout')), FRAME_ACK_TIMEOUT_MS)),
      ]);
    } catch (error) {
      // A missed ack just means the next frame arrives late; screencasting is
      // best-effort by design and must never take the session down.
    }
  }

  // Applies one input event from the client. Unknown/malformed events are
  // ignored rather than thrown — a stray or replayed message from a flaky
  // connection must not end the session.
  async handleInput(message) {
    if (!this._handle || this._ended) return;
    this._resetIdleTimer();
    const { cdp } = this._handle;
    try {
      switch (message && message.kind) {
        case 'mouseMove':
          await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: num(message.x), y: num(message.y) });
          break;
        case 'mouseDown':
        case 'mouseUp':
          await cdp.send('Input.dispatchMouseEvent', {
            type: message.kind === 'mouseDown' ? 'mousePressed' : 'mouseReleased',
            x: num(message.x),
            y: num(message.y),
            button: MOUSE_BUTTONS.has(message.button) ? message.button : 'left',
            clickCount: 1,
          });
          break;
        case 'wheel':
          await cdp.send('Input.dispatchMouseEvent', {
            type: 'mouseWheel', x: num(message.x), y: num(message.y),
            deltaX: num(message.deltaX), deltaY: num(message.deltaY),
          });
          break;
        case 'insertText':
          if (typeof message.text === 'string' && message.text.length) {
            await cdp.send('Input.insertText', { text: message.text });
          }
          break;
        case 'key': {
          const named = NAMED_KEYS[message.key];
          if (!named) break;
          await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...named });
          await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...named });
          break;
        }
        default:
          break;
      }
    } catch (error) {
      // The page may be mid-navigation when an event arrives; drop it rather
      // than tearing down the whole session over one lost click.
    }
  }

  // Ends the session and reports what the profile ended up holding. Safe to
  // call more than once (client "Done", idle timeout, and disconnect cleanup
  // can all race to call it) and safe to call on a session that never
  // finished starting.
  async finish() {
    if (this._ended) return this._result;
    this._ended = true;
    clearTimeout(this._idleTimer);
    if (this._handle) {
      // Closing the context (rather than killing it) is what makes Chrome
      // flush pending cookies to disk — the whole point of the session.
      await this._handle.dispose();
      this._handle = null;
    }
    this._result = accountMetadata.recordSignInResult(this.userId);
    return this._result;
  }
}

class SignInRegistry {
  constructor() {
    this._sessions = new Map();
  }

  // One session per user: a second attempt would either contend for the same
  // profile directory or silently abandon the first session's browser.
  async begin(userId, provider) {
    if (this._sessions.has(userId)) {
      throw new Error('A sign-in for this account is already in progress. Finish or close it before starting another.');
    }
    const session = new SignInSession(userId, provider);
    this._sessions.set(userId, session);
    try {
      await session.start();
    } catch (error) {
      this._sessions.delete(userId);
      throw error;
    }
    session.once('timeout', () => this._sessions.delete(userId));
    return session;
  }

  get(userId) {
    return this._sessions.get(userId) || null;
  }

  async end(userId) {
    const session = this._sessions.get(userId);
    if (!session) return null;
    this._sessions.delete(userId);
    return session.finish();
  }
}

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

module.exports = { SignInSession, SignInRegistry, registry: new SignInRegistry() };
