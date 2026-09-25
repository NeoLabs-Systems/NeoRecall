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
  const adminAccess = require('./services/auth/admin_access_service');
  const { reportRetiredCredentials } = require('./services/auth/retired_admin_report');
  const logger = createLogger('server');
  // NEORECALL_ADMIN_USERS grants admin on every start, and who the admins are is
  // logged each time, so an upgrade that turned the first account into the admin
  // is visible in the log. An install whose accounts include no admin gets a
  // pointer to the CLI rather than a silently unreachable Admin page. Under the
  // supervisor the old dashboard's credentials are already retired; this covers
  // an HTTP process started on its own.
  const applyStartupAdminAccess = () => {
    reportRetiredCredentials(logger);
    const { granted, missing, revoked } = adminAccess.applyEnvAdminGrants();
    if (granted.length) logger.info('Granted admin from NEORECALL_ADMIN_USERS', { usernames: granted });
    if (missing.length) {
      logger.warn('NEORECALL_ADMIN_USERS names accounts that do not exist; those names are reserved until removed from the list', { usernames: missing });
    }
    if (revoked.length) {
      logger.warn('NEORECALL_ADMIN_USERS lists accounts revoked with the CLI, left as they are; use `neorecall admin grant <username>` to restore them', { usernames: revoked });
    }
    if (adminAccess.needsAdminGrant()) {
      logger.warn('No account is an admin, so nobody can open the Admin page. Run `neorecall admin grant <username>`.');
    } else {
      const admins = adminAccess.listAdmins().map((admin) => admin.username);
      if (admins.length) logger.info('Admin accounts', { usernames: admins });
    }
  };
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
  Promise.resolve()
    .then(() => require('./db/migrate').migrate())
    .then(applyStartupAdminAccess)
    .then(() => {
      require('./services/sources').init();
      const config = getConfig();
      const server = createApp().listen(config.port, config.host, () => logger.info('NeoRecall HTTP server listening', { host: config.host, port: config.port }));
      for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
    }).catch((error) => { logger.error('Server startup failed', { error }); process.exitCode = 1; });
} else {
  throw new Error(`Unknown NEORECALL_ROLE: ${process.env.NEORECALL_ROLE}`);
}
