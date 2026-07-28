'use strict';

const path = require('node:path');
const express = require('express');
const compression = require('compression');
const { migrate } = require('./db/migrate');
const { getDatabase, isVectorReady, expectedVecVersion } = require('./db/database');
const { getConfig } = require('./config');
const { requestId } = require('./middleware/request_id');
const { cors } = require('./middleware/cors');
const { slidingWindow } = require('./middleware/rate_limit');
const { notFound, errorHandler, HttpError } = require('./middleware/error_handler');
const { hasBundledWebClient } = require('../lib/install_helpers');
const { WEB_CLIENT_DIR } = require('../runtime/paths');

function createApp() {
  migrate();
  const app = express();
  const config = getConfig();
  if (config.trustProxy) app.set('trust proxy', 1);
  app.disable('x-powered-by');
  app.use(requestId, cors, compression());
  app.use(express.json({ limit: '1mb' }));
  app.get('/health', (_req, res) => res.json({ status: 'ok', process: 'http', version: require('../package.json').version }));
  app.get('/ready', async (req, res, next) => {
    try {
      getDatabase().prepare('SELECT 1').get();
      const worker = getDatabase().prepare('SELECT * FROM worker_heartbeats ORDER BY heartbeat_at DESC LIMIT 1').get();
      const workerReady = Boolean(worker && Date.now() - Date.parse(worker.heartbeat_at) < 20_000);
      const modelReady = await require('./transcription/provider_registry').getProvider().ready();
      const ready = workerReady && modelReady && isVectorReady();
      res.status(ready ? 200 : 503).json({ status: ready ? 'ready' : 'not_ready', database: true,
        worker: workerReady, models: modelReady, vector: isVectorReady(), vectorVersion: expectedVecVersion });
    } catch (error) { next(error); }
  });
  app.use(require('./routes/oauth'));
  app.use(['/api/v1', '/admin/api/v1'], slidingWindow({ windowMs: 5 * 60_000, limit: 2000 }));
  app.use('/api/v1', require('./routes'));
  app.use('/admin/api/v1', require('./routes/admin'));
  app.use('/admin', express.static(path.join(__dirname, 'admin'), { extensions: ['html'] }));
  const appWebRoot = WEB_CLIENT_DIR;
  app.use('/app', express.static(appWebRoot, { extensions: ['html'], fallthrough: true }));
  app.use('/app', (req, res, next) => {
    if (!hasBundledWebClient(appWebRoot)) {
      return next(new HttpError(503, 'WEB_UI_MISSING', 'NeoRecall web UI assets are missing. Run `neorecall rebuild-web` or `neorecall repair`.'));
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return next();
    return res.sendFile(path.join(appWebRoot, 'index.html'), (error) => next(error));
  });
  app.use('/', express.static(path.join(__dirname, '..', 'landing'), { extensions: ['html'] }));
  app.use(notFound, errorHandler);
  return app;
}

module.exports = { createApp };
