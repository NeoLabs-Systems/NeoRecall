'use strict';

const diagnostics = require('../services/diagnostics/diagnostic_service');
const { createLogger } = require('../utils/logger');

const logger = createLogger('diagnostics');

function userDiagnostics(req, res, next) {
  const startedAt = process.hrtime.bigint();
  res.once('finish', () => {
    if (!req.auth?.userId || !req.originalUrl.startsWith('/api/v1')) return;
    const elapsedNs = process.hrtime.bigint() - startedAt;
    // This runs on the response's 'finish' event, outside every Express error
    // boundary, so anything thrown here reaches the process as an uncaught
    // exception. Account deletion made that concrete: the request that removes
    // the user row finishes, this handler tries to file a diagnostics row
    // against it, the foreign key fails, and the server exits. Diagnostics are
    // an observability convenience and must never be able to end a request —
    // let alone the process — so the write is contained here.
    try {
      diagnostics.recordRequest({
        userId: req.auth.userId,
        requestId: req.id,
        method: req.method,
        path: req.originalUrl,
        statusCode: res.statusCode,
        durationMs: Number(elapsedNs / 1_000_000n),
        errorCode: res.locals.diagnosticErrorCode,
      });
    } catch (error) {
      logger.warn('Could not record a request diagnostic', { path: req.originalUrl, error });
    }
  });
  next();
}

module.exports = { userDiagnostics };
