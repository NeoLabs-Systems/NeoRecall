'use strict';

const express = require('express');
const authService = require('../services/auth/auth_service');
const {
  SCOPES,
  createCompanionClient,
  registerPublicClient,
  validateAuthorizationRequest,
  createAuthorizationCode,
  exchangeAuthorizationCode,
  refreshTokenSet,
  revokeToken,
  authenticateAccessToken,
  createBrowserGrant,
  authenticateBrowserGrant,
  createPendingTwoFactorGrant,
  authenticatePendingTwoFactorGrant,
} = require('../services/auth/oauth_service');
const {
  publicBaseUrl, callerBaseUrl, authorizationServerMetadata, protectedResourceMetadata,
} = require('../services/auth/oauth_urls');
const { slidingWindow } = require('../middleware/rate_limit');
const { getConfig } = require('../config');
const { page, renderSignIn, renderConsent, renderError } = require('./oauth_pages');

const router = express.Router();
const OAUTH_COOKIE = 'neorecall_oauth_session';
const PENDING_2FA_COOKIE = 'neorecall_oauth_2fa';
router.use(express.urlencoded({ extended: false, limit: '32kb' }));

function appendRedirect(url, values) {
  const target = new URL(url);
  for (const [key, value] of Object.entries(values)) if (value) target.searchParams.set(key, value);
  return target.toString();
}

function requestParams(params) {
  return new URLSearchParams(Object.entries(params).map(([key, value]) => [key, String(value || '')])).toString();
}

function normalizeContinuePath(value) {
  const raw = String(value || '').trim();
  try {
    const parsed = new URL(raw, 'http://localhost');
    return parsed.pathname === '/oauth/authorize' ? `${parsed.pathname}${parsed.search}` : '/oauth/authorize';
  } catch {
    return '/oauth/authorize';
  }
}

function parseCookies(req) {
  return String(req.get('cookie') || '').split(';').reduce((cookies, part) => {
    const separator = part.indexOf('=');
    if (separator < 1) return cookies;
    const key = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (key) cookies[key] = decodeURIComponent(value);
    return cookies;
  }, {});
}

function oauthSession(req) {
  return authenticateBrowserGrant(parseCookies(req)[OAUTH_COOKIE]);
}

function cookieMaxAgeSeconds(ms) {
  return Math.max(1, Math.ceil(Number(ms) / 1000));
}

function oauthSessionMaxAge() {
  return cookieMaxAgeSeconds(getConfig().oauthBrowserGrantTtlMs);
}

function pendingTwoFactorMaxAge() {
  return cookieMaxAgeSeconds(getConfig().oauthPendingTwoFactorTtlMs);
}

function setOauthSessionCookie(req, res, grant) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${OAUTH_COOKIE}=${encodeURIComponent(grant)}; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=${oauthSessionMaxAge()}${secure ? '; Secure' : ''}`);
}

function setPendingTwoFactorCookie(req, res, grant) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${PENDING_2FA_COOKIE}=${encodeURIComponent(grant)}; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=${pendingTwoFactorMaxAge()}${secure ? '; Secure' : ''}`);
}

function clearPendingTwoFactorCookie(req, res) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${PENDING_2FA_COOKIE}=; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=0${secure ? '; Secure' : ''}`);
}

function clearOauthSessionCookie(req, res) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${OAUTH_COOKIE}=; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=0${secure ? '; Secure' : ''}`);
}

router.post('/api/oauth/companion/neoagent/bootstrap', slidingWindow({ windowMs: 15 * 60_000, limit: 80 }), (req, res) => {
  try {
    const issued = createCompanionClient({ redirectUri: req.body?.redirectUri, appName: req.body?.appName });
    const root = callerBaseUrl(req);
    return res.json({
      companion: 'neoagent', created: issued.created, clientId: issued.client.id,
      redirectUri: JSON.parse(issued.client.redirect_uris_json)[0], scopes: SCOPES,
      authorizationEndpoint: `${root}/oauth/authorize`, tokenEndpoint: `${root}/oauth/token`,
      userinfoEndpoint: `${root}/oauth/userinfo`, metadataEndpoint: `${root}/.well-known/oauth-authorization-server`,
    });
  } catch (error) {
    return res.status(error.statusCode || 400).json({ error: error.message });
  }
});

router.get('/.well-known/oauth-authorization-server', (req, res) => {
  res.json(authorizationServerMetadata(callerBaseUrl(req), SCOPES));
});

function sendProtectedResource(req, res) {
  res.json(protectedResourceMetadata(callerBaseUrl(req), SCOPES));
}
router.get('/.well-known/oauth-protected-resource', sendProtectedResource);
router.get('/.well-known/oauth-protected-resource/mcp', sendProtectedResource);

router.post('/oauth/register', slidingWindow({ windowMs: 15 * 60_000, limit: 80 }), (req, res) => {
  try {
    return res.status(201).json(registerPublicClient(req.body || {}));
  } catch (error) {
    return res.status(error.statusCode || 400).json({ error: 'invalid_client_metadata', error_description: error.message });
  }
});

router.get('/oauth/sign-in', (req, res) => {
  const continuePath = normalizeContinuePath(req.query.continue);
  if (oauthSession(req)) return res.redirect(continuePath);
  clearPendingTwoFactorCookie(req, res);
  return page(res, renderSignIn(continuePath));
});

router.post('/oauth/sign-in', slidingWindow({ windowMs: 60_000, limit: 10 }), async (req, res) => {
  const continuePath = normalizeContinuePath(req.body?.continue);
  const context = { ipAddress: req.ip, userAgent: req.get('User-Agent') };
  const pending = authenticatePendingTwoFactorGrant(parseCookies(req)[PENDING_2FA_COOKIE]);
  try {
    let user;
    if (pending && req.body?.two_factor_code) {
      user = await authService.completeTwoFactor(pending.userId, req.body.two_factor_code, context);
    } else {
      user = await authService.authenticateCredentials({
        account: req.body?.account,
        password: req.body?.password,
        twoFactorCode: req.body?.two_factor_code || undefined,
      }, context);
    }
    clearPendingTwoFactorCookie(req, res);
    setOauthSessionCookie(req, res, createBrowserGrant(user.id));
    return res.redirect(continuePath);
  } catch (error) {
    if (error.code === 'TWO_FACTOR_REQUIRED' && error.userId) {
      setPendingTwoFactorCookie(req, res, createPendingTwoFactorGrant({
        userId: error.userId,
        account: req.body?.account,
      }));
      return page(res, renderSignIn(continuePath, '', req.body?.account, true));
    }
    const stayOnTwoFactor = Boolean(pending) && (error.code === 'INVALID_TWO_FACTOR' || error.code === 'TWO_FACTOR_LOCKED');
    const account = stayOnTwoFactor ? (pending.account || req.body?.account) : req.body?.account;
    return page(res.status(error.status || error.statusCode || 400), renderSignIn(continuePath, error.message, account, stayOnTwoFactor));
  }
});

router.get('/oauth/authorize', (req, res) => {
  try {
    const authorize = validateAuthorizationRequest(req.query);
    if (!oauthSession(req)) return res.redirect(`/oauth/sign-in?continue=${encodeURIComponent(`/oauth/authorize?${requestParams(req.query)}`)}`);
    return page(res, renderConsent(authorize), authorize.redirectUri);
  } catch (error) {
    return page(res.status(error.statusCode || 400), renderError(error.message));
  }
});

router.post('/oauth/authorize', (req, res) => {
  try {
    const authorize = validateAuthorizationRequest(req.body);
    const loggedIn = oauthSession(req);
    if (!loggedIn) return res.redirect(`/oauth/sign-in?continue=${encodeURIComponent(`/oauth/authorize?${requestParams(req.body)}`)}`);
    if (String(req.body?.decision || '') !== 'approve') {
      clearOauthSessionCookie(req, res);
      return res.redirect(appendRedirect(authorize.redirectUri, { error: 'access_denied', state: authorize.state }));
    }
    const code = createAuthorizationCode({
      clientId: authorize.client.id, userId: loggedIn.userId, redirectUri: authorize.redirectUri,
      scopes: authorize.scopes, codeChallenge: authorize.codeChallenge,
    });
    clearOauthSessionCookie(req, res);
    return res.redirect(appendRedirect(authorize.redirectUri, { code, state: authorize.state }));
  } catch (error) {
    return page(res.status(error.statusCode || 400), renderError(error.message));
  }
});

router.post('/oauth/token', slidingWindow({ windowMs: 60_000, limit: 60 }), (req, res) => {
  try {
    const clientId = String(req.body?.client_id || '').trim();
    const grant = String(req.body?.grant_type || '').trim();
    const tokens = grant === 'authorization_code'
      ? exchangeAuthorizationCode({ clientId, code: req.body?.code, redirectUri: req.body?.redirect_uri, codeVerifier: req.body?.code_verifier })
      : grant === 'refresh_token'
        ? refreshTokenSet({ clientId, refreshToken: req.body?.refresh_token })
        : null;
    if (!tokens) return res.status(400).json({ error: 'unsupported_grant_type' });
    return res.json({ access_token: tokens.accessToken, token_type: 'Bearer', expires_in: tokens.expiresIn,
      refresh_token: tokens.refreshToken, scope: tokens.scope });
  } catch (error) {
    return res.status(error.statusCode || 400).json({ error: 'invalid_grant', error_description: error.message });
  }
});

router.post('/oauth/revoke', (req, res) => {
  try {
    revokeToken({ clientId: req.body?.client_id, token: req.body?.token });
    return res.status(200).send('');
  } catch (error) {
    return res.status(error.statusCode || 400).json({ error: error.message });
  }
});

router.get('/oauth/userinfo', (req, res) => {
  const token = String(req.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const authenticated = authenticateAccessToken(token);
  if (!authenticated) return res.status(401).json({ error: 'Unauthorized' });
  return res.json({
    sub: String(authenticated.userId), preferred_username: authenticated.user.username,
    email: authenticated.user.email, client_id: authenticated.clientId, client_name: authenticated.clientName,
  });
});

module.exports = router;
