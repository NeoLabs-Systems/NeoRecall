'use strict';

const express = require('express');
const authService = require('../services/auth/auth_service');
const {
  SCOPES,
  createCompanionClient,
  validateAuthorizationRequest,
  createAuthorizationCode,
  exchangeAuthorizationCode,
  refreshTokenSet,
  revokeToken,
  authenticateAccessToken,
  createBrowserGrant,
  authenticateBrowserGrant,
} = require('../services/auth/oauth_service');
const { slidingWindow } = require('../middleware/rate_limit');
const { getConfig } = require('../config');

const router = express.Router();
const OAUTH_COOKIE = 'neorecall_oauth_session';
router.use(express.urlencoded({ extended: false, limit: '32kb' }));

function escapeHtml(value) {
  return String(value || '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function publicBaseUrl(req) {
  return String(getConfig().publicUrl || `${req.protocol}://${req.get('host')}`).replace(/\/+$/, '');
}

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

function setOauthSessionCookie(req, res, grant) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${OAUTH_COOKIE}=${encodeURIComponent(grant)}; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=900${secure ? '; Secure' : ''}`);
}

function clearOauthSessionCookie(req, res) {
  const secure = new URL(publicBaseUrl(req)).protocol === 'https:';
  res.append('Set-Cookie', `${OAUTH_COOKIE}=; Path=/oauth; HttpOnly; SameSite=Lax; Max-Age=0${secure ? '; Secure' : ''}`);
}

function page(res, html) {
  res.set({
    'Cache-Control': 'no-store, max-age=0',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
  });
  return res.type('html').send(html);
}

function shell(title, eyebrow, content) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)} · NeoRecall</title><style>
  :root{color-scheme:light dark;--bg:#f4f1e8;--surface:rgba(253,252,248,.82);--surface-solid:#fdfcf8;--ink:#1c2117;--ink-2:#49503f;--ink-3:#7e8470;--line:rgba(28,33,23,.10);--line-2:rgba(28,33,23,.16);--gold:#b07d2b;--gold-soft:#c8943f;--rose:#a8506e;--sage:#5e6b4c;--btn:#1c2117;--btn-ink:#fdfcf8;--btn-hover:#2a3226;--shadow:0 18px 48px -24px rgba(28,33,23,.28), 0 8px 20px -12px rgba(28,33,23,.12);--sans:"Inter",ui-sans-serif,system-ui,sans-serif;--mono:"IBM Plex Mono",ui-monospace,monospace;}@media (prefers-color-scheme: dark){:root{--bg:#0e1511;--surface:rgba(23,31,26,.78);--surface-solid:#171f1a;--ink:#ecefe5;--ink-2:#aeb7a6;--ink-3:#7e8877;--line:rgba(224,240,224,.08);--line-2:rgba(224,240,224,.14);--gold:#e1b052;--gold-soft:#eac272;--rose:#d98aa6;--sage:#84ba87;--btn:#e1b052;--btn-ink:#0e1511;--btn-hover:#eac272;--shadow:0 24px 60px -28px rgba(0,0,0,.65), 0 10px 24px -16px rgba(0,0,0,.35);}}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at 12% 8%,color-mix(in srgb,var(--gold) 16%,transparent),transparent 28%),radial-gradient(circle at 88% 18%,color-mix(in srgb,var(--rose) 12%,transparent),transparent 24%),var(--bg);color:var(--ink);font-family:var(--sans);-webkit-font-smoothing:antialiased}.card{width:min(560px,100%);padding:32px;border:1px solid var(--line);border-radius:24px;background:var(--surface);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);box-shadow:var(--shadow)}.eyebrow{font-family:var(--mono);font-size:11px;font-weight:600;letter-spacing:1.7px;text-transform:uppercase;color:var(--gold-soft)}.brand{display:flex;align-items:center;gap:12px;margin-bottom:28px}.mark{width:38px;height:38px;display:grid;place-items:center;border-radius:12px;background:color-mix(in srgb,var(--rose) 14%,transparent);border:1px solid color-mix(in srgb,var(--rose) 35%,transparent);color:var(--rose);font-weight:900;font-size:18px}.brand strong{font-size:18px}h1{margin:8px 0 10px;font-size:30px;line-height:1.1;font-weight:800;letter-spacing:-0.9px}p{color:var(--ink-2);line-height:1.6}.field{margin-top:16px}label{display:block;margin-bottom:8px;color:var(--ink);font-size:13px;font-weight:700}input{width:100%;padding:13px 14px;border:1px solid var(--line-2);border-radius:12px;background:var(--surface-solid);color:var(--ink);font:inherit;outline:none;transition:border-color .2s,box-shadow .2s}input:focus{border-color:var(--gold);box-shadow:0 0 0 3px color-mix(in srgb,var(--gold) 12%,transparent)}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:28px}button{padding:12px 20px;border:1px solid transparent;border-radius:999px;font:inherit;font-weight:700;font-size:14px;cursor:pointer;transition:transform .2s,background .2s,border-color .2s}.primary{background:var(--btn);color:var(--btn-ink)}.primary:hover{background:var(--btn-hover);transform:translateY(-1px)}.secondary{background:transparent;color:var(--ink);border-color:var(--line-2)}.secondary:hover{transform:translateY(-1px)}.error{padding:12px 16px;margin-top:16px;border-radius:12px;background:color-mix(in srgb,#de5f70 12%,transparent);border:1px solid color-mix(in srgb,#de5f70 35%,transparent);color:#de5f70}.scope{display:flex;gap:14px;align-items:flex-start;padding:14px 0;border-top:1px solid var(--line)}.scope:first-child{border-top:0}.scope i{width:8px;height:8px;margin-top:7px;border-radius:50%;background:var(--sage)}.scope b{display:block;color:var(--ink)}.scope span{display:block;color:var(--ink-3);font-size:13px;margin-top:4px}.redirect{padding:14px;border-radius:12px;background:var(--surface-solid);border:1px solid var(--line);color:var(--ink-3);font-family:var(--mono);font-size:12px;overflow-wrap:anywhere}
  </style></head><body><main class="card"><div class="brand"><div class="mark">R</div><div><div class="eyebrow">${escapeHtml(eyebrow)}</div><strong>NeoRecall</strong></div></div>${content}</main></body></html>`;
}

function renderSignIn(continuePath, error = '', account = '', password = '', requiresTwoFactor = false) {
  if (requiresTwoFactor) {
    return shell('Two-factor authentication', 'NEOAGENT CONNECTION', `<h1>Two-factor authentication</h1><p>Enter the 6-digit code from your authenticator app, or a recovery code.</p>${error ? `<div class="error">${escapeHtml(error)}</div>` : ''}<form method="post" action="/oauth/sign-in"><input type="hidden" name="continue" value="${escapeHtml(continuePath)}"><input type="hidden" name="account" value="${escapeHtml(account)}"><input type="hidden" name="password" value="${escapeHtml(password)}"><div class="field"><label for="two_factor_code">Authenticator code</label><input id="two_factor_code" name="two_factor_code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="11" placeholder="123 456" spellcheck="false" autocorrect="off" autocapitalize="none" required autofocus></div><div class="actions"><button class="primary" type="submit">Verify</button></div><div style="margin-top:14px;text-align:center;"><a href="/oauth/sign-in?continue=${encodeURIComponent(continuePath)}" style="color:var(--ink-2);font-size:12px;text-decoration:none;">← Back</a></div></form>`);
  }
  return shell('Sign in', 'NEOAGENT CONNECTION', `<h1>Sign in to approve access</h1><p>Use your NeoRecall account. Your password is verified by this NeoRecall server and is never sent to NeoAgent.</p>${error ? `<div class="error">${escapeHtml(error)}</div>` : ''}<form method="post" action="/oauth/sign-in"><input type="hidden" name="continue" value="${escapeHtml(continuePath)}"><div class="field"><label for="account">Username or email</label><input id="account" name="account" autocomplete="username" value="${escapeHtml(account)}" required ${!account ? 'autofocus' : ''}></div><div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required ${account ? 'autofocus' : ''}></div><div class="actions"><button class="primary" type="submit">Sign in securely</button></div></form>`);
}

function renderConsent(authorize) {
  const hidden = Object.entries({
    response_type: 'code', client_id: authorize.client.id, redirect_uri: authorize.redirectUri,
    state: authorize.state, scope: authorize.scopes.join(' '), code_challenge: authorize.codeChallenge,
    code_challenge_method: 'S256',
  }).map(([key, value]) => `<input type="hidden" name="${key}" value="${escapeHtml(value)}">`).join('');
  const labels = {
    'search:read': ['Search your recall', 'Run local keyword and semantic searches without invoking NeoRecall Ask.'],
    'memories:read': ['Read memories', 'Read memories, mini-memories, entities, and daily summaries.'],
    'recordings:read': ['Read transcript evidence', 'Read conversations and transcript evidence; audio is never available.'],
  };
  const scopes = authorize.scopes.map((scope) => `<div class="scope"><i></i><div><b>${escapeHtml(labels[scope]?.[0] || scope)}</b><span>${escapeHtml(labels[scope]?.[1] || scope)}</span></div></div>`).join('');
  return shell('Authorize NeoAgent', 'EXPLICIT CONSENT', `<h1>Connect NeoAgent?</h1><p>NeoAgent requests read-only access to this account. It cannot record audio, modify memories, or trigger NeoRecall’s LLM.</p><div>${scopes}</div><p>After approval, return credentials only to:</p><div class="redirect">${escapeHtml(authorize.redirectUri)}</div><form method="post" action="/oauth/authorize">${hidden}<div class="actions"><button class="primary" type="submit" name="decision" value="approve">Authorize NeoAgent</button><button class="secondary" type="submit" name="decision" value="deny">Deny</button></div></form>`);
}

router.post('/api/oauth/companion/neoagent/bootstrap', slidingWindow({ windowMs: 15 * 60_000, limit: 80 }), (req, res) => {
  try {
    const issued = createCompanionClient({ redirectUri: req.body?.redirectUri, appName: req.body?.appName });
    const root = publicBaseUrl(req);
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
  const root = publicBaseUrl(req);
  res.json({
    issuer: root, authorization_endpoint: `${root}/oauth/authorize`, token_endpoint: `${root}/oauth/token`,
    revocation_endpoint: `${root}/oauth/revoke`, userinfo_endpoint: `${root}/oauth/userinfo`,
    grant_types_supported: ['authorization_code', 'refresh_token'], response_types_supported: ['code'],
    code_challenge_methods_supported: ['S256'], scopes_supported: SCOPES,
  });
});

router.get('/oauth/sign-in', (req, res) => {
  const continuePath = normalizeContinuePath(req.query.continue);
  if (oauthSession(req)) return res.redirect(continuePath);
  return page(res, renderSignIn(continuePath));
});

router.post('/oauth/sign-in', slidingWindow({ windowMs: 60_000, limit: 10 }), async (req, res) => {
  const continuePath = normalizeContinuePath(req.body?.continue);
  try {
    const user = await authService.authenticateCredentials({
      account: req.body?.account,
      password: req.body?.password,
      twoFactorCode: req.body?.two_factor_code || undefined,
    }, { ipAddress: req.ip, userAgent: req.get('User-Agent') });
    setOauthSessionCookie(req, res, createBrowserGrant(user.id));
    return res.redirect(continuePath);
  } catch (error) {
    if (error.code === 'TWO_FACTOR_REQUIRED') {
      return page(res, renderSignIn(continuePath, '', req.body?.account, req.body?.password, true));
    }
    return page(res.status(error.status || error.statusCode || 400), renderSignIn(continuePath, error.message, req.body?.account, req.body?.password, !!req.body?.two_factor_code));
  }
});

router.get('/oauth/authorize', (req, res) => {
  try {
    const authorize = validateAuthorizationRequest(req.query);
    if (!oauthSession(req)) return res.redirect(`/oauth/sign-in?continue=${encodeURIComponent(`/oauth/authorize?${requestParams(req.query)}`)}`);
    return page(res, renderConsent(authorize));
  } catch (error) {
    return page(res.status(error.statusCode || 400), shell('Authorization error', 'CONNECTION ERROR', `<h1>Authorization failed</h1><div class="error">${escapeHtml(error.message)}</div>`));
  }
});

router.post('/oauth/authorize', (req, res) => {
  try {
    const authorize = validateAuthorizationRequest(req.body);
    const loggedIn = oauthSession(req);
    if (!loggedIn) return res.redirect(`/oauth/sign-in?continue=${encodeURIComponent(`/oauth/authorize?${requestParams(req.body)}`)}`);
    clearOauthSessionCookie(req, res);
    if (String(req.body?.decision || '') !== 'approve') {
      return res.redirect(appendRedirect(authorize.redirectUri, { error: 'access_denied', state: authorize.state }));
    }
    const code = createAuthorizationCode({
      clientId: authorize.client.id, userId: loggedIn.userId, redirectUri: authorize.redirectUri,
      scopes: authorize.scopes, codeChallenge: authorize.codeChallenge,
    });
    return res.redirect(appendRedirect(authorize.redirectUri, { code, state: authorize.state }));
  } catch (error) {
    return page(res.status(error.statusCode || 400), shell('Authorization error', 'CONNECTION ERROR', `<h1>Authorization failed</h1><div class="error">${escapeHtml(error.message)}</div>`));
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
