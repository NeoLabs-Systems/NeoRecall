'use strict';

const { chromium } = require('playwright-extra');
const stealth = require('puppeteer-extra-plugin-stealth')();
chromium.use(stealth);

const EventEmitter = require('events');
const crypto = require('crypto');
const ingest = require('../../ingest/ingest_service');
const { getDatabase } = require('../../../db/database');

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
    this.sessionId = null;
    this.audioSourceId = null;
    this.isRecording = false;
  }

  async start() {
    console.log(`[MeetingBot] Starting bot for ${this.url}`);

    try {
      // In Docker, we rely on Xvfb being running globally, or we can use xvfb-maybe if needed.
      // For now we assume the container has Xvfb running or we are on macOS locally.
      console.log('[MeetingBot] Launching Chromium...');
      this.browser = await chromium.launch({
        headless: true, // Use headless=new or true. In playwright true is fine.
        args: [
          '--no-sandbox',
          '--disable-setuid-sandbox',
          '--disable-gpu',
          '--disable-dev-shm-usage',
          '--use-fake-ui-for-media-stream', // Auto-grant permissions
          '--use-fake-device-for-media-stream',
        ]
      });
      console.log('[MeetingBot] Chromium launched. Creating browser context...');

      this.context = await this.browser.newContext({
        permissions: ['microphone', 'camera']
      });
      console.log('[MeetingBot] Context created. Opening page...');
      this.page = await this.context.newPage();
      console.log('[MeetingBot] Page opened.');

      this.page.on('close', () => {
        this.emit('ended');
      });

      console.log('[MeetingBot] Setting up audio capture...');
      await this.setupAudioCapture();
      console.log('[MeetingBot] Audio capture ready. Joining meeting...');
      await this.joinMeeting();
      console.log('[MeetingBot] joinMeeting() returned; bot is in the meeting.');

      // Start silence detection / participant monitoring
      this.monitorTask = setInterval(() => this.checkMeetingStatus(), 10000);
    } catch (err) {
      console.error('[MeetingBot] start() failed:', err && err.stack ? err.stack : err);
      throw err;
    }
  }

  async setupAudioCapture() {
    console.log('[MeetingBot] setupAudioCapture: registering device + session...');
    const db = getDatabase();
    const deviceId = 'meeting-' + this.sourceId;
    const existing = db.prepare('SELECT id FROM devices WHERE id=?').get(deviceId);
    if (!existing) {
      db.prepare(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind)
        VALUES (?, ?, ?, ?, ?, ?)`).run(deviceId, this.userId, deviceId, 'Meeting Bot: ' + this.botName, 'web', 'import');
    }

    this.sessionId = crypto.randomUUID();
    ingest.createSession(this.userId, {
      deviceId,
      clientUuid: this.sessionId,
      startedAt: new Date().toISOString(),
      timezone: 'UTC',
      sources: []
    });

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

    console.log('[MeetingBot] setupAudioCapture: exposing sendAudioChunk...');
    // We expose a function that the page can call to send float32 PCM data
    await this.page.exposeFunction('sendAudioChunk', (float32ArrayObj) => {
      if (!this.isRecording) return;
      // Convert the object back to Float32Array
      // The payload will be sent as an array of numbers or Base64. Let's assume an array of numbers for simplicity
      const floatArray = Float32Array.from(Object.values(float32ArrayObj));
      // Ingest processAudio expects a Buffer of f32le
      const buffer = Buffer.from(floatArray.buffer);
      ingest.processAudio(this.userId, this.sessionId, this.audioSourceId, buffer);
    });

    // In a real implementation we'd wait until the meeting actually starts to inject this,
    // but we can define the helper here.
    this.page.on('load', async () => {
      try {
        await this.page.evaluate(() => {
           window.startAudioCapture = async () => {
             if (window._audioCaptureStarted) return;
             window._audioCaptureStarted = true;
             try {
               // Capture audio from the tab
               // In Chrome, tab audio capture extension might be needed, 
               // OR we hook into AudioContext. 
               // For meetings, they play audio via <audio> or <video> tags. We can capture their streams.
               const elements = [...document.querySelectorAll('audio, video')];
               if (elements.length === 0) return;
               
               const ctx = new AudioContext({ sampleRate: 48000 });
               const dest = ctx.createMediaStreamDestination();
               
               elements.forEach(el => {
                 try {
                   const source = ctx.createMediaElementSource(el);
                   source.connect(dest);
                   source.connect(ctx.destination); // keep playing it
                 } catch(e) {}
               });

               // Now we process the combined stream
               await ctx.audioWorklet.addModule(URL.createObjectURL(new Blob([`
                 class RecorderWorklet extends AudioWorkletProcessor {
                   process(inputs, outputs, parameters) {
                     const input = inputs[0];
                     if (input && input.length > 0 && input[0].length > 0) {
                       this.port.postMessage(input[0]); // Send mono channel
                     }
                     return true;
                   }
                 }
                 registerProcessor('recorder-worklet', RecorderWorklet);
               `], { type: 'application/javascript' })));

               const node = new AudioWorkletNode(ctx, 'recorder-worklet');
               node.port.onmessage = (e) => {
                 // Send to Node.js
                 window.sendAudioChunk(e.data);
               };
               
               const streamSource = ctx.createMediaStreamSource(dest.stream);
               streamSource.connect(node);
               node.connect(ctx.destination);

             } catch (err) {
               console.error("Audio capture error:", err);
             }
           };
        });
      } catch (e) {}
    });
  }

  async joinMeeting() {
    throw new Error('joinMeeting() must be implemented by child class');
  }

  async checkMeetingStatus() {
    // Basic implementation: if page is closed, stop
    if (this.page.isClosed()) {
      this.stop();
    }
  }

  async stop() {
    if (this.monitorTask) clearInterval(this.monitorTask);
    this.isRecording = false;

    if (this.sessionId) {
      ingest.closeSession(this.userId, this.sessionId, { endedAt: new Date().toISOString() });
      this.sessionId = null;
    }

    if (this.browser) {
      await this.browser.close();
      this.browser = null;
    }
    this.emit('ended');
  }
}

module.exports = AbstractBot;
