'use strict';

// Orchestrates OAuth start/callback for meeting platform sources: mint state,
// exchange the code, upsert the source row, and start polling.

const oauth = require('./outbound_oauth');
const { resolveProvider, listPlatformDefs, isMeetingPlatform } = require('../platforms/catalog');
const { getConfig } = require('../../../config');
const { HttpError } = require('../../../middleware/error_handler');

function publicBase(req) {
  const configured = getConfig().publicUrl;
  if (configured) return String(configured).replace(/\/+$/, '');
  const host = req.get('host');
  if (!host) {
    throw new HttpError(500, 'PUBLIC_URL_REQUIRED', 'NEORECALL_PUBLIC_URL must be set for OAuth redirects.');
  }
  return `${req.protocol}://${host}`.replace(/\/+$/, '');
}

function redirectUri(req, providerType) {
  return `${publicBase(req)}/api/v1/sources/oauth/${encodeURIComponent(providerType)}/callback`;
}

function appReturnUrl(req, { status, provider, message }) {
  const base = `${publicBase(req)}/app/`;
  const url = new URL(base);
  url.searchParams.set('sources_oauth', status);
  if (provider) url.searchParams.set('provider', provider);
  if (message) url.searchParams.set('message', message);
  return url.toString();
}

function beginAuthorize(req, userId, providerType) {
  if (!isMeetingPlatform(providerType)) {
    throw new HttpError(404, 'UNKNOWN_PROVIDER', `Unknown meeting platform: ${providerType}`);
  }
  const provider = resolveProvider(providerType);
  if (!provider.available) {
    throw new HttpError(503, 'PROVIDER_NOT_CONFIGURED', provider.unavailableReason);
  }
  if (!getConfig().publicUrl && !req.get('host')) {
    throw new HttpError(500, 'PUBLIC_URL_REQUIRED', 'NEORECALL_PUBLIC_URL must be set for OAuth redirects.');
  }

  const pkce = provider.usePkce ? oauth.pkcePair() : null;
  const state = oauth.issueState({
    userId,
    provider: providerType,
    codeVerifier: pkce?.verifier || null,
  });
  const authorizeUrl = oauth.buildAuthorizeUrl(provider, {
    redirectUri: redirectUri(req, providerType),
    state,
    codeChallenge: pkce?.challenge || null,
  });
  return {
    authorizeUrl,
    provider: providerType,
    label: provider.label,
    expiresInMs: oauth.STATE_TTL_MS,
  };
}

async function completeAuthorize(req, providerType, { code, state, error, errorDescription }) {
  if (error) {
    const message = errorDescription || error;
    return {
      redirectTo: appReturnUrl(req, {
        status: 'error',
        provider: providerType,
        message: `Sign-in was cancelled or failed: ${message}`,
      }),
    };
  }
  if (!code) {
    throw new HttpError(400, 'OAUTH_CODE_MISSING', 'The provider did not return an authorization code.');
  }

  const claimed = oauth.consumeState(state);
  if (claimed.provider !== providerType) {
    throw new HttpError(400, 'OAUTH_PROVIDER_MISMATCH', 'The sign-in session does not match this provider.');
  }

  const provider = resolveProvider(providerType);
  if (!provider.available) {
    throw new HttpError(503, 'PROVIDER_NOT_CONFIGURED', provider.unavailableReason);
  }

  const tokens = await oauth.exchangeCode(provider, {
    code,
    redirectUri: redirectUri(req, providerType),
    codeVerifier: claimed.codeVerifier || null,
  });

  const sources = require('../index');
  const adapter = loadAdapter(providerType);

  // Temporary source-shaped object so identity calls can use authorizedFetch.
  const provisional = {
    id: 'oauth-provisional',
    user_id: claimed.userId,
    type: providerType,
    config: oauth.configFromTokens(tokens),
  };

  let identity = { accountEmail: null, accountId: null, displayName: null };
  try {
    identity = await adapter.verifyIdentity(provisional, {
      updateConfig: (patch) => {
        provisional.config = { ...provisional.config, ...patch };
      },
    });
  } catch (identityError) {
    console.warn(`[sources-oauth] Identity lookup failed for ${providerType}:`, identityError.message);
  }

  const config = {
    ...oauth.configFromTokens(tokens),
    accountEmail: identity.accountEmail || null,
    accountId: identity.accountId || null,
    displayName: identity.displayName || null,
    pollMinutes: 15,
    connectedAt: new Date().toISOString(),
  };

  const existing = sources.list(claimed.userId).find((row) => row.type === providerType);
  let source;
  if (existing) {
    // list() redacts secrets — load full record for update merge.
    source = sources.update(claimed.userId, existing.id, {
      name: provider.defaultName,
      enabled: true,
      config,
    });
  } else {
    source = sources.create(claimed.userId, {
      type: providerType,
      name: provider.defaultName,
      enabled: true,
      config,
    });
  }

  return {
    source,
    redirectTo: appReturnUrl(req, { status: 'success', provider: providerType }),
  };
}

function loadAdapter(providerType) {
  switch (providerType) {
    case 'zoom':
      return require('../platforms/zoom');
    case 'google_meet':
      return require('../platforms/google_meet');
    case 'microsoft_teams':
      return require('../platforms/microsoft_teams');
    default:
      throw new HttpError(404, 'UNKNOWN_PROVIDER', `Unknown meeting platform: ${providerType}`);
  }
}

function catalogForUser(userId) {
  const sources = require('../index');
  const connected = new Map(sources.list(userId).map((row) => [row.type, row]));
  const platforms = listPlatformDefs().map((provider) => {
    const source = connected.get(provider.type) || null;
    return {
      type: provider.type,
      label: provider.label,
      description: provider.description,
      auth: provider.auth,
      available: provider.available,
      unavailableReason: provider.unavailableReason,
      prerequisites: provider.prerequisites,
      connected: Boolean(source),
      sourceId: source?.id || null,
      accountEmail: source?.config?.accountEmail || null,
      enabled: source?.enabled ?? null,
      lastSyncAt: source?.config?.lastSyncAt || null,
      error: source?.config?.error || null,
    };
  });
  return { platforms };
}

module.exports = {
  beginAuthorize,
  completeAuthorize,
  catalogForUser,
  redirectUri,
  publicBase,
  appReturnUrl,
};
