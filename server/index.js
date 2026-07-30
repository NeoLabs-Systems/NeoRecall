#!/usr/bin/env node
'use strict';

require('../runtime/env').loadEnvironment();

if (!process.env.NEORECALL_ROLE) {
  require('./supervisor').start();
} else if (process.env.NEORECALL_ROLE === 'worker') {
  require('./workers');
} else if (process.env.NEORECALL_ROLE === 'http') {
  const { getConfig } = require('./config');
  const { createApp } = require('./app');
  const { createLogger } = require('./utils/logger');
  const adminAuth = require('./services/auth/admin_auth_service');
  const logger = createLogger('server');
  // Make silent deaths visible: an async error escaping a wrapped path (or a
  // process-level crash) otherwise leaves no trace and just returns a prompt.
  process.on('uncaughtException', (err) => {
    logger.error('Uncaught exception', { error: err && err.stack ? err.stack : String(err) });
    process.exit(1);
  });
  process.on('unhandledRejection', (reason) => {
    logger.error('Unhandled rejection', { reason: reason && reason.stack ? reason.stack : String(reason) });
  });
  process.on('exit', (code) => { if (code !== 0) console.error(`[server] HTTP process exiting with code ${code}`); });
  adminAuth.bootstrap().then(() => {
    require('./services/sources').init();
    const config = getConfig();
    const server = createApp().listen(config.port, config.host, () => logger.info('NeoRecall HTTP server listening', { host: config.host, port: config.port }));
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
  }).catch((error) => { logger.error('Server startup failed', { error }); process.exitCode = 1; });
} else {
  throw new Error(`Unknown NEORECALL_ROLE: ${process.env.NEORECALL_ROLE}`);
}
