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
      inferenceReady = message.ready === true;
      logger.info('Inference host readiness', { ready: message.ready, error: message.error });
    }
    const entry = pending.get(message.requestId);
    if (!entry) return;
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
function inference(input) {
  return new Promise((resolve, reject) => {
    if (!child || !child.connected) {
      reject(Object.assign(new Error('Inference host unavailable.'), { code: 'INFERENCE_HOST_EXITED' }));
      return;
    }
    const requestId = crypto.randomUUID();
    pending.set(requestId, { resolve, reject });
    child.send({ type: 'transcribe', requestId, input }, (err) => {
      if (err) { pending.delete(requestId); reject(Object.assign(err, { code: 'INFERENCE_HOST_EXITED' })); }
    });
  });
}

const controller = new AbortController();
spawnInferenceHost();
scheduler.start();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { controller.abort(); scheduler.stop(); child?.kill('SIGTERM'); });
runner.run({ inference, isInferenceReady: () => inferenceReady, signal: controller.signal })
  .catch((error) => { logger.error('Worker stopped unexpectedly', { error }); process.exitCode = 1; });
