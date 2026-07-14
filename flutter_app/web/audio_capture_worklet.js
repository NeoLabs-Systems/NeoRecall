'use strict';

if (typeof AudioWorkletProcessor !== 'undefined') {
  class NeoRecallPcmProcessor extends AudioWorkletProcessor {
    process(inputs) {
      // Copy engine-owned buffers before transferring them to the window.
      const microphone = new Float32Array(inputs[0]?.[0] || new Float32Array(128));
      const system = new Float32Array(inputs[1]?.[0] || new Float32Array(microphone.length));
      this.port.postMessage({ microphone, system }, [microphone.buffer, system.buffer]);
      return true;
    }
  }
  registerProcessor('neorecall-pcm-processor', NeoRecallPcmProcessor);
}

if (typeof window !== 'undefined') {
  window.NeoRecallCapture = (() => {
    let context, node, silentGain, microphoneStream, displayStream, persistenceTimer, persistenceChain = Promise.resolve();
    let left = [], right = [], startedAt, emittedOffsetMs = 0, options, systemActive = false, lastLevelAt = 0;
    const api = { onChunk: null, onWarning: null, onLevel: null };
    const requestPersistence = async () => Boolean(navigator.storage?.persist && await navigator.storage.persist());
    const wav = (leftSamples, rightSamples) => {
      const channels = rightSamples ? 2 : 1;
      const frames = leftSamples.length;
      const output = new ArrayBuffer(44 + frames * channels * 2);
      const view = new DataView(output); const write = (offset, text) => [...text].forEach((character, index) => view.setUint8(offset + index, character.charCodeAt(0)));
      write(0, 'RIFF'); view.setUint32(4, output.byteLength - 8, true); write(8, 'WAVE'); write(12, 'fmt '); view.setUint32(16, 16, true);
      view.setUint16(20, 1, true); view.setUint16(22, channels, true); view.setUint32(24, context.sampleRate, true);
      view.setUint32(28, context.sampleRate * channels * 2, true); view.setUint16(32, channels * 2, true); view.setUint16(34, 16, true);
      write(36, 'data'); view.setUint32(40, output.byteLength - 44, true);
      let offset = 44;
      for (let index = 0; index < frames; index += 1) {
        const a = Math.max(-1, Math.min(1, leftSamples[index])); view.setInt16(offset, a < 0 ? a * 32768 : a * 32767, true); offset += 2;
        if (rightSamples) { const b = Math.max(-1, Math.min(1, rightSamples[index])); view.setInt16(offset, b < 0 ? b * 32768 : b * 32767, true); offset += 2; }
      }
      return new Uint8Array(output);
    };
    const persistPartial = async () => {
      if (!left.length) return;
      const request = indexedDB.open('neorecall-capture-recovery-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('partial');
      await new Promise((resolve, reject) => { request.onsuccess = resolve; request.onerror = reject; });
      const transaction = request.result.transaction('partial', 'readwrite');
      transaction.objectStore('partial').put({ left: new Float32Array(left), right: systemActive ? new Float32Array(right) : null,
        startedAt: startedAt.toISOString(), emittedOffsetMs, options, sampleRate: context.sampleRate }, 'active');
      await new Promise((resolve, reject) => { transaction.oncomplete = resolve; transaction.onerror = reject; }); request.result.close();
    };
    const clearPartial = async () => { const request = indexedDB.open('neorecall-capture-recovery-v1', 1); await new Promise((resolve, reject) => { request.onsuccess = resolve; request.onerror = reject; }); const transaction = request.result.transaction('partial', 'readwrite'); transaction.objectStore('partial').delete('active'); await new Promise((resolve, reject) => { transaction.oncomplete = resolve; transaction.onerror = reject; }); request.result.close(); };
    const queuePersistence = () => { persistenceChain = persistenceChain.then(persistPartial).catch(() => { api.onWarning?.('Browser storage could not persist the active audio block. Recording will stop if the durable chunk queue cannot accept more data.'); }); return persistenceChain; };
    const emit = (frames, isFinal) => {
      if (!frames) return;
      const durationMs = Math.round(frames / context.sampleRate * 1000);
      const bytes = wav(left.slice(0, frames), systemActive ? right.slice(0, frames) : null);
      api.onChunk?.(Array.from(bytes), { durationMs, overlapMs: emittedOffsetMs === 0 ? 0 : options.overlapMs,
        channelLayout: systemActive ? 'microphone_left_system_right' : 'mono', startedAt: new Date(startedAt.getTime() + emittedOffsetMs).toISOString(), monotonicOffsetMs: emittedOffsetMs, isFinal });
      const retain = isFinal ? 0 : Math.round(context.sampleRate * options.overlapMs / 1000);
      const consumed = Math.max(0, frames - retain); left = left.slice(consumed); right = right.slice(consumed); emittedOffsetMs += Math.round(consumed / context.sampleRate * 1000);
      if (!isFinal) queuePersistence();
    };
    api.requestPersistence = requestPersistence;
    api.start = async (requested) => {
      options = requested; startedAt = new Date(); emittedOffsetMs = 0; left = []; right = []; systemActive = false;
      const persistentStorage = await requestPersistence(); let warning = persistentStorage ? null : 'Persistent browser storage was not granted. Keep this tab open and monitor available storage.';
      context = new AudioContext({ sampleRate: 16000 }); await context.audioWorklet.addModule('audio_capture_worklet.js');
      node = new AudioWorkletNode(context, 'neorecall-pcm-processor', { numberOfInputs: 2, numberOfOutputs: 1, outputChannelCount: [1] });
      if (requested.microphone) { microphoneStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false }, video: false }); context.createMediaStreamSource(microphoneStream).connect(node, 0, 0); }
      if (requested.systemAudio) {
        try { displayStream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true }); const tracks = displayStream.getAudioTracks(); if (!tracks.length) throw new Error('The selected surface did not expose audio.'); context.createMediaStreamSource(new MediaStream(tracks)).connect(node, 0, 1); systemActive = true;
          tracks[0].addEventListener('ended', () => { systemActive = false; warning = 'Screen-share audio ended. Microphone recording is still active.'; api.onWarning?.(warning); });
        } catch (_) { systemActive = false; warning = 'System audio was not shared. Recording continues with the microphone only.'; }
      }
      if (!requested.microphone && !systemActive) throw new Error('No audio source is active.');
      silentGain = context.createGain(); silentGain.gain.value = 0; node.connect(silentGain).connect(context.destination);
      node.port.onmessage = (event) => {
        left.push(...event.data.microphone); right.push(...event.data.system);
        const now = performance.now();
        if (now - lastLevelAt >= 100) {
          let energy = 0; let count = 0;
          for (const samples of [event.data.microphone, ...(systemActive ? [event.data.system] : [])]) {
            for (let index = 0; index < samples.length; index += 4) { energy += samples[index] * samples[index]; count += 1; }
          }
          api.onLevel?.(count ? Math.min(1, Math.sqrt(energy / count)) : 0); lastLevelAt = now;
        }
        const target = Math.round(context.sampleRate * options.chunkMs / 1000); while (left.length >= target) emit(target, false);
      };
      persistenceTimer = setInterval(async () => { queuePersistence(); const estimate = await navigator.storage?.estimate?.(); if (estimate?.quota && estimate.usage / estimate.quota >= .9) api.onWarning?.(`Browser storage is ${Math.round(estimate.usage / estimate.quota * 100)}% full. Keep NeoRecall online so acknowledged chunks can be released.`); }, 2000); await context.resume();
      return { microphone: requested.microphone, systemAudio: systemActive, persistentStorage, sampleRate: context.sampleRate, warning };
    };
    api.stop = async () => { clearInterval(persistenceTimer); await persistenceChain; if (left.length) emit(left.length, true); await clearPartial(); node?.disconnect(); microphoneStream?.getTracks().forEach((track) => track.stop()); displayStream?.getTracks().forEach((track) => track.stop()); await context?.close(); context = null; };
    return api;
  })();
}
