'use strict';

const adminAuth = require('../services/auth/admin_auth_service');
const { timingSafeStringEqual } = require('../utils/crypto');
const { HttpError } = require('./error_handler');

function requireAdmin(req, _res, next) {
  const header = req.get('Authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (process.env.ADMIN_API_KEY && timingSafeStringEqual(token, process.env.ADMIN_API_KEY)) {
    req.adminAuth = { type: 'api_key', adminId: null, username: 'api-key' }; return next();
  }
  const auth = adminAuth.authenticate(token);
  if (!auth) return next(new HttpError(401, 'ADMIN_AUTHENTICATION_REQUIRED', 'Administrator authentication is required.'));
  req.adminAuth = auth; return next();
}

module.exports = { requireAdmin };
