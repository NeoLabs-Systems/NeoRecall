'use strict';

const levels = Object.freeze({ debug: 10, info: 20, warn: 30, error: 40 });

function redact(key, value) {
  if (/token|password|secret|authorization|api.?key|audio|transcript/i.test(key)) return '[redacted]';
  if (value instanceof Error) return { name: value.name, message: value.message, stack: value.stack };
  return value;
}

function createLogger(scope) {
  const configured = levels[process.env.NEORECALL_LOG_LEVEL] || levels.info;
  const emit = (level, message, metadata = {}) => {
    if (levels[level] < configured) return;
    const record = { timestamp: new Date().toISOString(), level, scope, message, ...metadata };
    const line = JSON.stringify(record, redact);
    (level === 'error' ? process.stderr : process.stdout).write(`${line}\n`);
  };
  return {
    debug: (message, metadata) => emit('debug', message, metadata),
    info: (message, metadata) => emit('info', message, metadata),
    warn: (message, metadata) => emit('warn', message, metadata),
    error: (message, metadata) => emit('error', message, metadata),
  };
}

module.exports = { createLogger };
