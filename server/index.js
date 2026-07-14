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
  adminAuth.bootstrap().then(() => {
    const config = getConfig();
    const server = createApp().listen(config.port, config.host, () => logger.info('NeoRecall HTTP server listening', { host: config.host, port: config.port }));
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
  }).catch((error) => { logger.error('Server startup failed', { error }); process.exitCode = 1; });
} else {
  throw new Error(`Unknown NEORECALL_ROLE: ${process.env.NEORECALL_ROLE}`);
}
