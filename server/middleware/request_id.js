'use strict';

const crypto = require('node:crypto');

function requestId(req, res, next) {
  req.id = req.get('X-Request-ID') || crypto.randomUUID();
  res.set('X-Request-ID', req.id);
  next();
}

module.exports = { requestId };
