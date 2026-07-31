'use strict';

const EventEmitter = require('events');
const crypto = require('crypto');
const ingest = require('../../ingest/ingest_service');
const { getDatabase } = require('../../../db/database');
const { getConfig } = require('../../../config');
const { createMeetingBrowser } = require('./browser_launcher');
const profileStore = require('./browser_profile');
const meetingAccounts = require('./meeting_account_service');

class AbstractBot extends EventEmitter {
  constructor(userId, sourceId, botName, url) {
    super();
    this.userId = userId;
    this.sourceId = sourceId;
    this.botName = botName;
    this.url = url;
    this.browser = null;
    this.page = null;
    this.context = null;
    this._disposeBrowser = null;
    this._profile = null;
    this.sessionId = null;
    this.audioSourceId = null;
    this.isRecording = false;
    // True once the bot was actually admitted — the difference between "the
    // meeting is over" and "the join never happened", which the source uses to
    // decide whether to retire the link or keep the failure visible.
    this.hasJoined = false;
    this._stopping = false;
    this.monitorTask = null;
    // What account (if any) the bot is joining as — the platform bots use this
    // to explain a refusal precisely instead of guessing at the cause.
    this.connection = { signedIn: false, connected: {}, identity: null };
    this._absentSince = null;
  }

  async start() {
    console.log(`[MeetingBot] Starting bot for ${this.url}`);

    try {
      // Join as the account the user connected, if they connected one. The
      // profile is cloned per session, so a crash or a killed browser can never
      // damage the signed-in original.
      this._profile = await profileStore.checkoutForSession(this.userId);
      this.connection = meetingAccounts.describeConnection(this.userId);
      console.log(this._profile.dir
        ? `[MeetingBot] Using the connected browser profile${this.connection.identity ? ` (${this.connection.identity})` : ''}.`
        : '[MeetingBot] No connected account; joining anonymously.');

      // The launcher picks the least-detectable browser strategy available
      // (external CDP → spawn real Chrome + attach over CDP → direct launch),
      // headful and off-screen. See browser_launcher.js for the rationale.
      const headlessFallback = process.env.MEETING_BOT_HEADLESS === 'new';
      const launched = await createMeetingBrowser({
        extraArgs: this.extraChromiumArgs(),
        headlessFallback,
        userDataDir: this._profile.dir,
      });
      this.browser = launched.browser;
      this.context = launched.context;
      this.page = launched.page;
      this._disposeBrowser = launched.dispose;
      console.log(`[MeetingBot] Browser ready (${launched.mode}).`);

      // A closed tab ends the meeting for us. Route it through stop() so the
      // session is closed and the browser/profile are released — emitting
      // 'ended' on its own used to leave both behind.
      this.page.on('close', () => {
        this.stop().catch((error) => console.error('[MeetingBot] Teardown after tab close failed:', error.message));
      });

      console.log('[MeetingBot] Registering session (no page injection yet)...');
      await this.registerSession();
      console.log('[MeetingBot] Joining meeting on a clean page...');
      await this.joinMeeting();
      // Admitted: NOW it's safe to inject the capture pipeline.
      await this.beginAudioCapture();
      console.log('[MeetingBot] Bot admitted and capturing.');

      // Watch for the call ending. The timer must swallow its own failures — an
      // unhandled rejection from a background tick would take the process down.
      this.monitorTask = setInterval(() => {
        this.checkMeetingStatus().catch((error) => console.error('[MeetingBot] Status check failed:', error.message));
      }, 10000);
    } catch (err) {
      console.error('[MeetingBot] start() failed:', err && err.stack ? err.stack : err);
      // A failed join used to leave the browser process, the profile clone and
      // an open DB session behind — one refused meeting then leaked a Chrome
      // instance for the lifetime of the server.
      await this.releaseResources();
      throw err;
    }
  }

  // DB-only session registration. Runs BEFORE joining and touches nothing in the
  // page — so the pre-join / join screens carry no automation artifacts.
  async registerSession() {
    console.log('[MeetingBot] registerSession: device + session...');
    const db = getDatabase();
    const deviceId = 'meeting-' + this.sourceId;
    const existing = db.prepare('SELECT id FROM devices WHERE id=?').get(deviceId);
    if (!existing) {
      db.prepare(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind)
        VALUES (?, ?, ?, ?, ?, ?)`).run(deviceId, this.userId, deviceId, 'Meeting Bot: ' + this.botName, 'web', 'import');
    }

    const clientUuid = crypto.randomUUID();
    const startedAt = new Date().toISOString();
    // createSession assigns its own row id; keep that authoritative id for all
    // later addSource/processAudio/closeSession calls (they resolve by row id,
    // not client_uuid). Using the client_uuid here would 404 as "session not found".
    const { session } = ingest.createSession(this.userId, {
      deviceId,
      clientUuid,
      startedAt,
      timezone: 'UTC',
      // The user attests consent to record by adding and enabling this Meeting
      // Link source; attest at session start. Mirrors the import path, which
      // sets consent_attested_at to the import's created_at (see import_handler).
      consentAttestedAt: startedAt,
      sources: []
    });
    this.sessionId = session.id;

    this.audioSourceId = crypto.randomUUID();
    ingest.addSource(this.userId, this.sessionId, {
      id: this.audioSourceId,
      clientUuid: this.audioSourceId,
      kind: 'microphone',
      channelLayout: 'mono',
      sampleRate: 48000,
      sampleFormat: 'f32le',
      metadata: { botName: this.botName, url: this.url }
    });
  }

  // Injects the capture pipeline ONLY after the bot is admitted, so the join is
  // fingerprinted on a clean page — exposeFunction/addInitScript on the pre-join
  // page are automation tells Google's join-step bot check can flag. Taps the
  // WebRTC MediaStreams Meet attaches to <audio>/<video> via el.srcObject
  // (createMediaElementSource yields SILENCE for WebRTC-backed elements). Remote
  // streams attach after admission and change over the call, so we rescan.
  async beginAudioCapture() {
    console.log('[MeetingBot] beginAudioCapture: injecting capture (post-admission)...');
    this.hasJoined = true;
    await this.page.exposeFunction('sendAudioChunk', (float32ArrayObj) => {
      if (!this.isRecording) return;
      const floatArray = Float32Array.from(Object.values(float32ArrayObj));
      const buffer = Buffer.from(floatArray.buffer);
      ingest.processAudio(this.userId, this.sessionId, this.audioSourceId, buffer);
    });

    await this.page.evaluate(async () => {
      if (window._audioCaptureStarted) return;
      window._audioCaptureStarted = true;
      try {
        const ctx = new AudioContext({ sampleRate: 48000 });
        if (ctx.state === 'suspended') { try { await ctx.resume(); } catch (e) {} }

        await ctx.audioWorklet.addModule(URL.createObjectURL(new Blob([`
          class RecorderWorklet extends AudioWorkletProcessor {
            constructor() { super(); this._buf = []; this._len = 0; }
            process(inputs) {
              const ch = inputs[0] && inputs[0][0];
              if (ch && ch.length) {
                this._buf.push(ch.slice(0)); this._len += ch.length;
                if (this._len >= 4800) { // ~100ms @ 48kHz — batch to cut IPC
                  const out = new Float32Array(this._len); let o = 0;
                  for (const b of this._buf) { out.set(b, o); o += b.length; }
                  this.port.postMessage(out); this._buf = []; this._len = 0;
                }
              }
              return true;
            }
          }
          registerProcessor('recorder-worklet', RecorderWorklet);
        `], { type: 'application/javascript' })));

        const node = new AudioWorkletNode(ctx, 'recorder-worklet');
        let framesSent = 0;
        node.port.onmessage = (e) => {
          framesSent++;
          if (framesSent === 1 || framesSent % 50 === 0) console.log('[capture] audio frames sent:', framesSent);
          window.sendAudioChunk(e.data);
        };
        const silent = ctx.createGain(); silent.gain.value = 0;
        node.connect(silent); silent.connect(ctx.destination);

        const seen = new WeakSet();
        const attach = (stream, tag) => {
          if (!stream || seen.has(stream) || !stream.getAudioTracks || stream.getAudioTracks().length === 0) return;
          seen.add(stream);
          try {
            ctx.createMediaStreamSource(stream).connect(node);
            console.log('[capture] attached', tag, 'stream; audioTracks:', stream.getAudioTracks().length);
          } catch (err) { console.error('[capture] attach failed for', tag, err && err.message); }
        };
        const scan = () => {
          const els = [...document.querySelectorAll('audio, video')];
          let withStream = 0;
          for (const el of els) if (el.srcObject && el.srcObject.getAudioTracks) { withStream++; attach(el.srcObject, el.tagName); }
          if (withStream) console.log('[capture] media elements:', els.length, '| with stream:', withStream);
        };

        scan();
        new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
        setInterval(scan, 3000); // Meet reassigns srcObject over the call's life.
        console.log('[capture] started; ctx.state =', ctx.state);
      } catch (err) {
        console.error('[capture] fatal error:', err && (err.stack || err.message));
      }
    });
  }

  async joinMeeting() {
    throw new Error('joinMeeting() must be implemented by child class');
  }

  // Platform bots override to add Chromium flags (e.g. Teams needs fake media
  // devices to drive its pre-join toggles). Default: none.
  extraChromiumArgs() { return []; }

  // Selector that is present exactly while the bot is in the call (the "leave
  // call" control). Platform bots override it so the monitor below can tell that
  // the meeting ended or the bot was removed.
  admittedSelector() { return null; }

  // Ends the recording when the call is over. Previously the bot only noticed a
  // closed tab, so a meeting that simply ended left it recording silence — and
  // holding the session open — until the server restarted.
  async checkMeetingStatus() {
    if (!this.page || this.page.isClosed()) {
      await this.stop();
      return;
    }
    const selector = this.admittedSelector();
    if (!selector || !this.isRecording) return;

    const inCall = await this.page.locator(selector).first().isVisible().catch(() => null);
    if (inCall === null) return; // page busy/navigating — no verdict this tick
    if (inCall) {
      this._absentSince = null;
      return;
    }
    if (this._absentSince === null) {
      this._absentSince = Date.now();
      return;
    }
    if (Date.now() - this._absentSince >= getConfig().meetingLeaveGraceMs) {
      console.log('[MeetingBot] No longer in the call (meeting ended or bot removed); stopping.');
      await this.stop();
    }
  }

  async stop() {
    // Teardown re-enters itself: closing the browser fires the page 'close'
    // handler, which stops the bot again. Let the first call win.
    if (this._stopping) return;
    this._stopping = true;
    if (this.monitorTask) {
      clearInterval(this.monitorTask);
      this.monitorTask = null;
    }
    this.isRecording = false;
    await this.releaseResources();
    this.emit('ended');
  }

  // Idempotent teardown shared by stop() and the failed-start path: flush audio,
  // close the session, kill the browser, delete the profile clone.
  async releaseResources() {
    // Flush any buffered tail audio into a final chunk before closing the session.
    if (this.audioSourceId) {
      ingest.finalizeAudio(this.audioSourceId);
      this.audioSourceId = null;
    }

    if (this.sessionId) {
      ingest.closeSession(this.userId, this.sessionId, { endedAt: new Date().toISOString() });
      this.sessionId = null;
    }

    // dispose() closes the browser and, for the CDP-spawn strategy, also kills
    // the Chrome process and removes its temp profile.
    if (this._disposeBrowser) {
      const dispose = this._disposeBrowser;
      this._disposeBrowser = null;
      await dispose().catch((error) => console.error('[MeetingBot] Browser teardown failed:', error.message));
      this.browser = null;
    } else if (this.browser) {
      const browser = this.browser;
      this.browser = null;
      await browser.close().catch(() => {});
    }

    if (this._profile) {
      const profile = this._profile;
      this._profile = null;
      await profile.dispose();
    }
  }
}

module.exports = AbstractBot;
