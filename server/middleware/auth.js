'use strict';

const authService = require('../services/auth/auth_service');
const apiKeys = require('../services/auth/api_key_service');
const oauth = require('../services/auth/oauth_service');
const { HttpError } = require('./error_handler');

function bearer(req) {
  const value = req.get('Authorization') || '';
  return value.startsWith('Bearer ') ? value.slice(7).trim() : null;
}

function requireAuth(req, _res, next) {
  const token = bearer(req);
  const auth = apiKeys.authenticate(token) || authService.authenticateToken(token) || oauth.authenticateAccessToken(token);
  if (!auth) return next(new HttpError(401, 'AUTHENTICATION_REQUIRED', 'A valid bearer token is required.'));
  req.auth = auth;
  req.user = auth.user;
  return next();
}

function requireScope(scope) {
  return (req, _res, next) => {
    if (req.auth?.scopes.includes('*') || req.auth?.scopes.includes(scope)) return next();
    return next(new HttpError(403, 'INSUFFICIENT_SCOPE', `The ${scope} scope is required.`));
  };
}

function requireAnyScope(...scopes) {
  return (req, _res, next) => {
    if (req.auth?.scopes.includes('*') || scopes.some((scope) => req.auth?.scopes.includes(scope))) return next();
    return next(new HttpError(403, 'INSUFFICIENT_SCOPE', `One of these scopes is required: ${scopes.join(', ')}.`));
  };
}

function requireSession(req, _res, next) {
  if (req.auth?.type === 'session') return next();
  return next(new HttpError(403, 'SESSION_REQUIRED', 'An interactive user session is required for this operation.'));
}

module.exports = { bearer, requireAuth, requireScope, requireAnyScope, requireSession };
