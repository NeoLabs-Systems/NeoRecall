'use strict';

const { getConfig } = require('../../config');

function publicBaseUrl(req) {
  return String(getConfig().publicUrl || `${req.protocol}://${req.get('host')}`).replace(/\/+$/, '');
}

function callerBaseUrl(req) {
  // Prefer the host the client actually used. A mis-set NEORECALL_PUBLIC_URL of
  // localhost breaks browser OAuth and MCP discovery on a LAN or reverse proxy.
  const forwardedProto = String(req.get('x-forwarded-proto') || '').split(',')[0].trim();
  const forwardedHost = String(req.get('x-forwarded-host') || '').split(',')[0].trim();
  const host = forwardedHost || String(req.get('host') || '').trim();
  if (!host) return publicBaseUrl(req);
  const protocol = forwardedProto || req.protocol || 'http';
  return `${protocol}://${host}`.replace(/\/+$/, '');
}

function authorizationServerMetadata(root, scopes) {
  return {
    issuer: root,
    authorization_endpoint: `${root}/oauth/authorize`,
    token_endpoint: `${root}/oauth/token`,
    revocation_endpoint: `${root}/oauth/revoke`,
    registration_endpoint: `${root}/oauth/register`,
    userinfo_endpoint: `${root}/oauth/userinfo`,
    grant_types_supported: ['authorization_code', 'refresh_token'],
    response_types_supported: ['code'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    scopes_supported: scopes,
  };
}

function protectedResourceMetadata(root, scopes) {
  return {
    resource: `${root}/mcp`,
    authorization_servers: [root],
    scopes_supported: scopes,
    bearer_methods_supported: ['header'],
  };
}

function wwwAuthenticate(root) {
  return `Bearer realm="NeoRecall", resource_metadata="${root}/.well-known/oauth-protected-resource"`;
}

module.exports = {
  publicBaseUrl, callerBaseUrl, authorizationServerMetadata, protectedResourceMetadata, wwwAuthenticate,
};
