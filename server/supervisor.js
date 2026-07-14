'use strict';

const path = require('node:path');
const { fork } = require('node:child_process');
const { createLogger } = require('./utils/logger');

const logger = createLogger('supervisor');

function start() {
  let stopping = false;
  const children = new Map();
  function spawn(role, script) {
    const child = fork(script, [], { env: { ...process.env, NEORECALL_ROLE: role }, stdio: 'inherit' });
    children.set(role, child);
    child.on('exit', (code, signal) => {
      children.delete(role);
      if (!stopping) { logger.warn('Child process exited; restarting', { role, code, signal }); setTimeout(() => spawn(role, script), 1000); }
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
