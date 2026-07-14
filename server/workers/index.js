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
function spawnInferenceHost() {
  child = fork(path.join(__dirname, 'inference_host.js'), [], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
  child.on('message', (message) => {
    if (message.type === 'ready') logger.info('Inference host readiness', { ready: message.ready, error: message.error });
    const entry = pending.get(message.requestId);
    if (!entry) return;
    pending.delete(message.requestId);
    if (message.type === 'result') entry.resolve(message.segments);
    else entry.reject(Object.assign(new Error(message.error.message), message.error));
  });
  child.on('exit', (code, signal) => {
    for (const entry of pending.values()) entry.reject(Object.assign(new Error('Inference host exited.'), { code: 'INFERENCE_HOST_EXITED' }));
    pending.clear();
    if (!controller.signal.aborted) { logger.warn('Restarting inference host', { code, signal }); spawnInferenceHost(); }
  });
}
function inference(input) {
  return new Promise((resolve, reject) => {
    const requestId = crypto.randomUUID();
    pending.set(requestId, { resolve, reject });
    child.send({ type: 'transcribe', requestId, input });
  });
}

const controller = new AbortController();
spawnInferenceHost();
scheduler.start();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { controller.abort(); scheduler.stop(); child?.kill('SIGTERM'); });
runner.run({ inference, signal: controller.signal }).catch((error) => { logger.error('Worker stopped unexpectedly', { error }); process.exitCode = 1; });
