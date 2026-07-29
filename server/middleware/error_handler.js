'use strict';

const { createLogger } = require('../utils/logger');
const logger = createLogger('http');

class HttpError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function notFound(_req, res) {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: 'The requested resource was not found.' } });
}

function errorHandler(error, req, res, _next) {
  const status = error.status || (error.code === 'LIMIT_FILE_SIZE' ? 413 : 500);
  const code = error.code || 'INTERNAL_ERROR';
  res.locals.diagnosticErrorCode = code;
  if (status >= 500) logger.error('Request failed', { requestId: req.id, method: req.method, path: req.path, error });
  const payload = {
    error: {
      code,
      message: status >= 500 && !(error instanceof HttpError) ? 'An internal error occurred.' : error.message,
      ...(error.details ? { details: error.details } : {}),
      requestId: req.id,
    },
  };
  res.status(status).json(payload);
}

module.exports = { HttpError, notFound, errorHandler };
