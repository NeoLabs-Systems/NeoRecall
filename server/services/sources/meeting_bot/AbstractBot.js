'use strict';

const EventEmitter = require('events');
const crypto = require('crypto');
const ingest = require('../../ingest/ingest_service');
const { getDatabase } = require('../../../db/database');
const { createMeetingBrowser } = require('./browser_launcher');

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
    this.sessionId = null;
    this.audioSourceId = null;
    this.isRecording = false;
  }

  async start() {
    console.log(`[MeetingBot] Starting bot for ${this.url}`);

    try {
      // The launcher picks the least-detectable browser strategy available
      // (external CDP → spawn real Chrome + attach over CDP → direct launch),
      // headful and off-screen. See browser_launcher.js for the rationale.
      const headlessFallback = process.env.MEETING_BOT_HEADLESS === 'new';
      const launched = await createMeetingBrowser({
        extraArgs: this.extraChromiumArgs(),
        headlessFallback,
      });
      this.browser = launched.browser;
      this.context = launched.context;
      this.page = launched.page;
      this._disposeBrowser = launched.dispose;
      console.log(`[MeetingBot] Browser ready (${launched.mode}).`);

      this.page.on('close', () => {
        this.emit('ended');
      });

      console.log('[MeetingBot] Registering session (no page injection yet)...');
      await this.registerSession();
      console.log('[MeetingBot] Joining meeting on a clean page...');
      await this.joinMeeting();
      // Admitted: NOW it's safe to inject the capture pipeline.
      await this.beginAudioCapture();
      console.log('[MeetingBot] Bot admitted and capturing.');

      // Start silence detection / participant monitoring
      this.monitorTask = setInterval(() => this.checkMeetingStatus(), 10000);
    } catch (err) {
      console.error('[MeetingBot] start() failed:', err && err.stack ? err.stack : err);
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

  async checkMeetingStatus() {
    // Basic implementation: if page is closed, stop
    if (this.page.isClosed()) {
      this.stop();
    }
  }

  async stop() {
    if (this.monitorTask) clearInterval(this.monitorTask);
    this.isRecording = false;

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
      await this._disposeBrowser();
      this._disposeBrowser = null;
      this.browser = null;
    } else if (this.browser) {
      await this.browser.close();
      this.browser = null;
    }
    this.emit('ended');
  }
}

module.exports = AbstractBot;
