'use strict';

const diagnostics = require('../services/diagnostics/diagnostic_service');

function userDiagnostics(req, res, next) {
  const startedAt = process.hrtime.bigint();
  res.once('finish', () => {
    if (!req.auth?.userId || !req.originalUrl.startsWith('/api/v1')) return;
    const elapsedNs = process.hrtime.bigint() - startedAt;
    diagnostics.recordRequest({
      userId: req.auth.userId,
      requestId: req.id,
      method: req.method,
      path: req.originalUrl,
      statusCode: res.statusCode,
      durationMs: Number(elapsedNs / 1_000_000n),
      errorCode: res.locals.diagnosticErrorCode,
    });
  });
  next();
}

module.exports = { userDiagnostics };
