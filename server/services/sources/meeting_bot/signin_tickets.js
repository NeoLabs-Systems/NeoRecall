'use strict';

// Single-use tickets that hand a specific, already-authorized sign-in session
// off to a WebSocket connection.
//
// The browser's WebSocket API cannot send a custom Authorization header, so
// the live sign-in relay (signin_relay.js) cannot be gated by the normal
// bearer token the way REST routes are. Instead, the authenticated REST call
// that starts the sign-in (`POST /meeting/account/sign-in`) mints a ticket;
// the client opens the WebSocket with that ticket in the URL. The ticket is
// consumed on first use, expires in a minute, and grants nothing beyond
// attaching to the one session it was minted for — unlike a bearer token, a
// leaked ticket in a log or proxy is worthless a minute later and cannot be
// replayed for a second connection. Mirrors pairing_service.js's token model.

const crypto = require('node:crypto');

const TICKET_TTL_MS = 60 * 1000;
const tickets = new Map();

function sweep() {
  const now = Date.now();
  for (const [token, entry] of tickets) {
    if (now - entry.issuedAt > TICKET_TTL_MS) tickets.delete(token);
  }
}

function issue(userId, providerId) {
  sweep();
  const token = crypto.randomBytes(24).toString('base64url');
  tickets.set(token, { userId, providerId, issuedAt: Date.now() });
  return token;
}

// Consumes the ticket if valid; returns null (and leaves nothing to retry —
// the ticket is gone either way) otherwise.
function redeem(token) {
  const entry = tickets.get(token);
  tickets.delete(token);
  if (!entry) return null;
  if (Date.now() - entry.issuedAt > TICKET_TTL_MS) return null;
  return { userId: entry.userId, providerId: entry.providerId };
}

module.exports = { issue, redeem, TICKET_TTL_MS };
