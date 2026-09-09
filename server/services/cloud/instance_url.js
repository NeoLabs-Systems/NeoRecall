'use strict';

const { HttpError } = require('../../middleware/error_handler');

// Nextcloud instance URLs come from the user. The server will POST to them
// (Login Flow) and PUT files (WebDAV), so a crafted URL is an SSRF primitive.
// The rules are: a real http(s) origin, no credentials, no link-local or
// metadata addresses, and plaintext HTTP only for private/local hosts.

const BLOCKED_HOSTS = new Set(['metadata.google.internal', 'metadata.google.internal.']);

function ipv4FromHost(hostname) {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(hostname);
  if (!match) return null;
  const parts = match.slice(1).map(Number);
  if (parts.some((part) => part > 255)) return null;
  return parts;
}

function isUnspecifiedOrLinkLocalIPv4(parts) {
  if (parts[0] === 0) return true;
  if (parts[0] === 169 && parts[1] === 254) return true;
  if (parts[0] === 255 && parts[1] === 255 && parts[2] === 255 && parts[3] === 255) return true;
  return false;
}

function isPrivateIPv4(parts) {
  if (parts[0] === 10) return true;
  if (parts[0] === 127) return true;
  if (parts[0] === 192 && parts[1] === 168) return true;
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
  return false;
}

function isLoopbackOrPrivateHost(hostname) {
  const host = hostname.toLowerCase().replace(/\.$/, '');
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  if (host === '::1' || host === '[::1]') return true;
  const ipv4 = ipv4FromHost(host);
  if (ipv4 && isPrivateIPv4(ipv4)) return true;
  return false;
}

function isBlockedHost(hostname) {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (BLOCKED_HOSTS.has(host)) return true;
  if (host === '::' || host === '0.0.0.0') return true;
  if (host.startsWith('fe80:')) return true;
  const ipv4 = ipv4FromHost(host);
  if (ipv4 && isUnspecifiedOrLinkLocalIPv4(ipv4)) return true;
  return false;
}

function invalid(message) {
  return new HttpError(400, 'INVALID_CLOUD_URL', message);
}

function normalizeInstanceUrl(raw) {
  const trimmed = String(raw || '').trim();
  if (!trimmed) throw invalid('A Nextcloud URL is required.');
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw invalid('That is not a valid URL.');
  }
  if (parsed.username || parsed.password) throw invalid('The Nextcloud URL must not include credentials.');
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw invalid('The Nextcloud URL must be http or https.');
  }
  if (!parsed.hostname) throw invalid('The Nextcloud URL is missing a host.');
  if (isBlockedHost(parsed.hostname)) throw invalid('That host cannot be used as a Nextcloud instance.');
  if (parsed.protocol === 'http:' && !isLoopbackOrPrivateHost(parsed.hostname)) {
    throw invalid('HTTP is only allowed for a local or private Nextcloud address. Use HTTPS otherwise.');
  }
  if (parsed.pathname.includes('..')) throw invalid('The Nextcloud URL path is invalid.');
  parsed.hash = '';
  parsed.search = '';
  const path = parsed.pathname.replace(/\/+$/, '');
  return `${parsed.origin}${path === '/' ? '' : path}`;
}

function originOf(url) {
  return new URL(url).origin;
}

function sameOrigin(left, right) {
  try {
    return originOf(left) === originOf(right);
  } catch {
    return false;
  }
}

function joinUrl(base, suffix) {
  const root = String(base).replace(/\/+$/, '');
  const path = String(suffix).replace(/^\/+/, '');
  return `${root}/${path}`;
}

module.exports = { normalizeInstanceUrl, sameOrigin, joinUrl, isLoopbackOrPrivateHost, isBlockedHost };
