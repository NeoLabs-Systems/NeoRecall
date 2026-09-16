'use strict';

require('../../runtime/env').loadEnvironment();
const path = require('node:path');
const crypto = require('node:crypto');
const { fork } = require('node:child_process');
const { migrate } = require('../db/migrate');
const runner = require('./worker_runner');
const scheduler = require('../services/jobs/scheduler_service');
const { createLogger } = require('../utils/logger');

const logger = createLogger('worker');
migrate();

let child;
const pending = new Map();
let inferenceReady = false;
const INFERENCE_RESTART_BASE_MS = 1_000;
const INFERENCE_RESTART_MAX_MS = 30_000;
const INFERENCE_HEALTHY_UPTIME_MS = 60_000;
let inferenceBackoffMs = INFERENCE_RESTART_BASE_MS;
function spawnInferenceHost() {
  const startedAt = Date.now();
  inferenceReady = false;
  child = fork(path.join(__dirname, 'inference_host.js'), [], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
  child.on('message', (message) => {
    if (message.type === 'ready') {
      const ready = message.ready === true;
      // Only log on change; the host polls readiness every few seconds.
      if (ready !== inferenceReady) {
        logger.info('Inference host readiness changed', { ready, error: message.error });
      }
      inferenceReady = ready;
    }
    const entry = pending.get(message.requestId);
    if (!entry) return;
    // Progress notes about a request still in flight, not its answer.
    if (message.type === 'diagnostics') { entry.onDiagnostics?.(message); return; }
    pending.delete(message.requestId);
    if (message.type === 'result') entry.resolve(message.segments);
    else entry.reject(Object.assign(new Error(message.error.message), message.error));
  });
  child.on('exit', (code, signal) => {
    inferenceReady = false;
    for (const entry of pending.values()) entry.reject(Object.assign(new Error('Inference host exited.'), { code: 'INFERENCE_HOST_EXITED' }));
    pending.clear();
    if (controller.signal.aborted) return;
    // Reset backoff when the host had a healthy run; otherwise grow it so a
    // model that crashes on load does not spin in a tight restart loop.
    if (Date.now() - startedAt >= INFERENCE_HEALTHY_UPTIME_MS) inferenceBackoffMs = INFERENCE_RESTART_BASE_MS;
    const delay = Math.min(inferenceBackoffMs, INFERENCE_RESTART_MAX_MS);
    inferenceBackoffMs = Math.min(delay * 2, INFERENCE_RESTART_MAX_MS);
    logger.warn('Restarting inference host', { code, signal, delayMs: delay });
    const timer = setTimeout(() => { if (!controller.signal.aborted) spawnInferenceHost(); }, delay);
    timer.unref();
  });
}
function inference(input, { onDiagnostics } = {}) {
  return new Promise((resolve, reject) => {
    if (!child || !child.connected) {
      reject(Object.assign(new Error('Inference host unavailable.'), { code: 'INFERENCE_HOST_EXITED' }));
      return;
    }
    const requestId = crypto.randomUUID();
    pending.set(requestId, { resolve, reject, onDiagnostics });
    child.send({ type: 'transcribe', requestId, input }, (err) => {
      if (err) { pending.delete(requestId); reject(Object.assign(err, { code: 'INFERENCE_HOST_EXITED' })); }
    });
  });
}

const controller = new AbortController();
spawnInferenceHost();
scheduler.start();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { controller.abort(); scheduler.stop(); child?.kill('SIGTERM'); });
// Written once at start-up so the top of any log answers "what is this pointed
// at" without a database query. Never fatal: a server that cannot describe its
// configuration should still try to run with it.
try {
  logger.info('Inference providers', require('../services/settings/provider_settings_service').describeForLog());
} catch (error) {
  logger.warn('Could not read the inference provider configuration', { error: error.message });
}
// Conditioning the audio that diarization hears changes the conditions a voice
// is measured under. Voices enrolled before this was switched on were measured
// without it, so the two are no longer directly comparable and a familiar
// person can start reading as somebody new. Said once, at start-up, and only
// when there is actually something already enrolled to be affected.
try {
  const { getConfig } = require('../config');
  if (getConfig().audioPreprocessTarget === 'stt+analysis') {
    const enrolled = require('../db/database').getDatabase().prepare('SELECT COUNT(*) count FROM voiceprints').get().count;
    if (enrolled) {
      logger.warn('Conditioned audio now also feeds speaker detection, and these voices were learned without it', {
        enrolledVoices: enrolled,
        remedy: 'Run the Speakers screen\'s re-detect once so recent recordings are resolved under the same conditions, or set NEORECALL_AUDIO_PREPROCESS_TARGET=stt to keep speaker detection on the original audio.',
      });
    }
  }
} catch (error) {
  logger.warn('Could not check enrolled voices against the audio conditioning mode', { error: error.message });
}

runner.run({ inference, isInferenceReady: () => inferenceReady, signal: controller.signal })
  .catch((error) => { logger.error('Worker stopped unexpectedly', { error }); process.exitCode = 1; });
