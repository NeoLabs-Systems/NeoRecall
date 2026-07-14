'use strict';

const { HttpError } = require('./error_handler');

function slidingWindow({ windowMs, limit, key = (req) => req.auth?.userId || req.ip, code = 'RATE_LIMITED' }) {
  const entries = new Map();
  const middleware = (req, res, next) => {
    if (limit === 0) return next(new HttpError(429, code, 'This operation is disabled.'));
    const now = Date.now();
    const cutoff = now - windowMs;
    const id = key(req);
    const recent = (entries.get(id) || []).filter((timestamp) => timestamp > cutoff);
    if (recent.length >= limit) {
      const retryAfter = Math.max(1, Math.ceil((recent[0] + windowMs - now) / 1000));
      res.set('Retry-After', String(retryAfter));
      return next(new HttpError(429, code, 'Too many requests. Please try again later.', { retryAfterSeconds: retryAfter }));
    }
    recent.push(now);
    entries.set(id, recent);
    if (entries.size > 10_000) {
      for (const [entryKey, timestamps] of entries) {
        if (!timestamps.some((timestamp) => timestamp > cutoff)) entries.delete(entryKey);
      }
    }
    return next();
  };
  middleware.clear = () => entries.clear();
  return middleware;
}

module.exports = { slidingWindow };
