'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

function loadCapture({ systemAudio = false } = {}) {
  let workletNode;
  const microphoneTrack = { stop() {} };
  const systemTrack = { stop() {}, addEventListener() {} };
  class AudioContext {
    constructor() {
      this.sampleRate = 16000;
      this.destination = {};
      this.audioWorklet = { addModule: async () => {} };
    }

    createMediaStreamSource() {
      return { connect() {} };
    }

    createGain() {
      return { gain: { value: 1 }, connect() { return this; } };
    }

    async resume() {}
    async close() {}
  }
  class AudioWorkletNode {
    constructor() {
      this.port = {};
      workletNode = this;
    }

    connect() {
      return this;
    }

    disconnect() {}
  }
  const sandbox = {
    AudioContext,
    AudioWorkletNode,
    Date,
    Error,
    Float32Array,
    MediaStream: class MediaStream {},
    Promise,
    Uint8Array,
    ArrayBuffer,
    DataView,
    Math,
    String,
    clearInterval() {},
    console,
    navigator: {
      storage: {
        persist: async () => true,
        estimate: async () => ({ quota: 100, usage: 0 }),
      },
      mediaDevices: {
        getUserMedia: async () => ({ getTracks: () => [microphoneTrack] }),
        getDisplayMedia: async () => ({
          getAudioTracks: () => (systemAudio ? [systemTrack] : []),
          getTracks: () => [systemTrack],
        }),
      },
    },
    performance: { now: () => 200 },
    setInterval: () => 1,
    window: {},
  };
  vm.createContext(sandbox);
  const source = fs.readFileSync(
    path.join(__dirname, '../../flutter_app/web/audio_capture_worklet.js'),
    'utf8',
  );
  vm.runInContext(source, sandbox);
  return {
    capture: sandbox.window.NeoRecallCapture,
    workletNode: () => workletNode,
  };
}

function start(capture, options) {
  return new Promise((resolve, reject) => {
    const returned = capture.start(
      options.microphone,
      options.systemAudio,
      options.chunkMs,
      options.overlapMs,
      (microphone, capturedSystemAudio, persistentStorage, sampleRate, warning) => resolve({
        microphone,
        systemAudio: capturedSystemAudio,
        persistentStorage,
        sampleRate,
        warning,
      }),
      reject,
    );
    assert.equal(returned, undefined);
  });
}

test('browser capture completes through callbacks without exposing a promise', async () => {
  const { capture } = loadCapture();
  const capability = await start(capture, {
    microphone: true,
    systemAudio: false,
    chunkMs: 30000,
    overlapMs: 2000,
  });

  assert.deepEqual(
    JSON.parse(JSON.stringify(capability)),
    {
      microphone: true,
      systemAudio: false,
      persistentStorage: true,
      sampleRate: 16000,
      warning: null,
    },
  );
});

test('system-only browser capture emits mono system samples', async () => {
  const { capture, workletNode } = loadCapture({ systemAudio: true });
  const chunks = [];
  capture.onChunk = (
    bytes,
    durationMs,
    overlapMs,
    channelLayout,
    startedAt,
    monotonicOffsetMs,
    isFinal,
  ) => chunks.push({
    bytes,
    metadata: {
      durationMs,
      overlapMs,
      channelLayout,
      startedAt,
      monotonicOffsetMs,
      isFinal,
    },
  });
  await start(capture, {
    microphone: false,
    systemAudio: true,
    chunkMs: 1,
    overlapMs: 0,
  });

  workletNode().port.onmessage({
    data: {
      microphone: new Float32Array(16),
      system: new Float32Array(16).fill(0.5),
    },
  });

  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].metadata.channelLayout, 'mono');
  assert.equal(chunks[0].bytes.length, 44 + 16 * 2);
  const wav = Uint8Array.from(chunks[0].bytes);
  assert.ok(new DataView(wav.buffer).getInt16(44, true) > 0);
});
