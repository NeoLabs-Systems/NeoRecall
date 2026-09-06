'use strict';

const path = require('node:path');
const { fork } = require('node:child_process');
const { createLogger } = require('./utils/logger');

const logger = createLogger('supervisor');

const RESTART_BASE_MS = 1_000;      // initial delay after a crash
const RESTART_MAX_MS = 30_000;      // ceiling for exponential backoff
const HEALTHY_UPTIME_MS = 60_000;   // uptime that proves a clean start and resets backoff

function start() {
  let stopping = false;
  const children = new Map();
  const backoff = new Map(); // role -> current restart delay in ms
  function spawn(role, script) {
    const startedAt = Date.now();
    const child = fork(script, [], { env: { ...process.env, NEORECALL_ROLE: role }, stdio: 'inherit' });
    children.set(role, child);
    child.on('exit', (code, signal) => {
      children.delete(role);
      if (stopping) return;
      // A process that stayed up long enough is treated as a healthy start:
      // reset its backoff so a later isolated crash recovers quickly.
      if (Date.now() - startedAt >= HEALTHY_UPTIME_MS) backoff.delete(role);
      const delay = Math.min(backoff.get(role) ?? RESTART_BASE_MS, RESTART_MAX_MS);
      backoff.set(role, Math.min(delay * 2, RESTART_MAX_MS));
      logger.warn('Child process exited; restarting', { role, code, signal, delayMs: delay });
      // Keep the timer on the event loop: if both children have crashed, an
      // unref'd restart is the only remaining handle and the supervisor would
      // otherwise exit 0 instead of bringing them back.
      setTimeout(() => { if (!stopping) spawn(role, script); }, delay);
    });
  }
  spawn('http', path.join(__dirname, 'index.js'));
  spawn('worker', path.join(__dirname, 'workers', 'index.js'));
  const shutdown = (signal) => {
    if (stopping) return; stopping = true;
    for (const child of children.values()) child.kill(signal);
    const timer = setTimeout(() => { for (const child of children.values()) child.kill('SIGKILL'); process.exit(1); }, 10_000);
    timer.unref();
    Promise.all([...children.values()].map((child) => new Promise((resolve) => child.once('exit', resolve)))).then(() => process.exit(0));
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

module.exports = { start };
