'use strict';

const crypto = require('node:crypto');
const {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} = require('@simplewebauthn/server');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const audit = require('../audit/audit_service');
const authService = require('./auth_service');

const RP_NAME = 'NeoRecall';
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const CEREMONY_TIMEOUT_MS = 2 * 60 * 1000;
const MAX_CREDENTIALS_PER_USER = 20;
const MAX_LABEL_LENGTH = 48;

function toBase64Url(bytes) { return Buffer.from(bytes).toString('base64url'); }
function fromBase64Url(value) { return new Uint8Array(Buffer.from(String(value), 'base64url')); }

function parseTransports(row) {
  try {
    const parsed = JSON.parse(row.transports || '[]');
    return Array.isArray(parsed) ? parsed.filter((entry) => typeof entry === 'string') : [];
  } catch {
    return [];
  }
}

function normalizeLabel(value, fallback) {
  const label = String(value || '').trim().replace(/\s+/g, ' ');
  if (!label) return fallback;
  if (label.length > MAX_LABEL_LENGTH) {
    throw new HttpError(400, 'INVALID_LABEL', `The security key name may contain at most ${MAX_LABEL_LENGTH} characters.`);
  }
  return label;
}

// A credential is bound to the exact hostname it was created on, so the relying
// party comes from the origin the ceremony actually runs on rather than from a
// single configured public URL. Only the server's own origin and the origins
// the CORS layer already trusts are accepted.
function resolveRelyingParty({ origin, selfOrigin }) {
  const configured = (process.env.NEORECALL_ALLOWED_ORIGINS || '').split(',').map((value) => value.trim()).filter(Boolean);
  const effective = String(origin || '').trim() || selfOrigin;
  if (effective !== selfOrigin && !configured.includes(effective) && !configured.includes('*')) {
    throw new HttpError(403, 'ORIGIN_NOT_ALLOWED', 'Security keys cannot be used from this origin.');
  }
  let hostname = '';
  try {
    hostname = new URL(effective).hostname;
  } catch {
    hostname = '';
  }
  if (!hostname) throw new HttpError(400, 'INVALID_ORIGIN', 'The request origin is not a valid address.');
  return { origin: effective, rpId: hostname };
}

function publicCredential(row) {
  return {
    id: row.id,
    label: row.label,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at || null,
    backedUp: row.backed_up === 1,
    rpId: row.rp_id,
  };
}

function listCredentials(userId) {
  return getDatabase()
    .prepare('SELECT * FROM user_webauthn_credentials WHERE user_id = ? ORDER BY created_at DESC')
    .all(userId)
    .map(publicCredential);
}

function credentialsForRelyingParty(userId, rpId) {
  return getDatabase()
    .prepare('SELECT credential_id, transports FROM user_webauthn_credentials WHERE user_id = ? AND rp_id = ?')
    .all(userId, rpId)
    .map((row) => ({ id: row.credential_id, transports: parseTransports(row) }));
}

function storeChallenge({ purpose, userId, challenge, rp }) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  const now = new Date();
  db.prepare('DELETE FROM webauthn_challenges WHERE expires_at <= ?').run(now.toISOString());
  db.prepare(`INSERT INTO webauthn_challenges (id, purpose, user_id, challenge, rp_id, origin, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .run(id, purpose, userId, challenge, rp.rpId, rp.origin, new Date(now.getTime() + CHALLENGE_TTL_MS).toISOString());
  return id;
}

// Challenges are single use: the row is removed as it is read, so a captured
// assertion cannot be replayed against the same challenge.
function consumeChallenge({ challengeId, purpose, rp }) {
  const db = getDatabase();
  const row = db.prepare('SELECT * FROM webauthn_challenges WHERE id = ? AND purpose = ?').get(String(challengeId || ''), purpose);
  if (row) db.prepare('DELETE FROM webauthn_challenges WHERE id = ?').run(row.id);
  if (!row || Date.parse(row.expires_at) <= Date.now()) {
    throw new HttpError(400, 'CHALLENGE_EXPIRED', 'The security key request expired. Please try again.');
  }
  if (row.rp_id !== rp.rpId || row.origin !== rp.origin) {
    throw new HttpError(400, 'CHALLENGE_ORIGIN_MISMATCH', 'The security key request was started from a different address.');
  }
  return row;
}

async function beginRegistration({ userId, username, rp }) {
  if (listCredentials(userId).length >= MAX_CREDENTIALS_PER_USER) {
    throw new HttpError(400, 'TOO_MANY_CREDENTIALS', `At most ${MAX_CREDENTIALS_PER_USER} security keys can be registered.`);
  }
  const options = await generateRegistrationOptions({
    rpName: RP_NAME,
    rpID: rp.rpId,
    userID: Buffer.from(String(userId), 'utf8'),
    userName: username,
    userDisplayName: username,
    attestationType: 'none',
    timeout: CEREMONY_TIMEOUT_MS,
    excludeCredentials: credentialsForRelyingParty(userId, rp.rpId),
    authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' },
  });
  return { challengeId: storeChallenge({ purpose: 'registration', userId, challenge: options.challenge, rp }), options };
}

async function completeRegistration({ userId, challengeId, response, label, rp }) {
  const challenge = consumeChallenge({ challengeId, purpose: 'registration', rp });
  if (challenge.user_id !== userId) {
    throw new HttpError(400, 'CHALLENGE_MISMATCH', 'The security key request belongs to another account.');
  }

  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge.challenge,
      expectedOrigin: rp.origin,
      expectedRPID: rp.rpId,
      requireUserVerification: false,
    });
  } catch (error) {
    throw new HttpError(400, 'CREDENTIAL_REJECTED', error.message || 'The security key could not be verified.');
  }
  if (!verification.verified || !verification.registrationInfo) {
    throw new HttpError(400, 'CREDENTIAL_REJECTED', 'The security key could not be verified.');
  }

  const { credential, credentialDeviceType, credentialBackedUp } = verification.registrationInfo;
  const db = getDatabase();
  if (db.prepare('SELECT 1 FROM user_webauthn_credentials WHERE credential_id = ?').get(credential.id)) {
    throw new HttpError(409, 'CREDENTIAL_EXISTS', 'This security key is already registered.');
  }
  const existingCount = listCredentials(userId).length;
  db.prepare(`INSERT INTO user_webauthn_credentials
    (id, user_id, credential_id, public_key, counter, rp_id, transports, device_type, backed_up, label)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(
      crypto.randomUUID(),
      userId,
      credential.id,
      toBase64Url(credential.publicKey),
      Number(credential.counter || 0),
      rp.rpId,
      JSON.stringify(credential.transports || []),
      credentialDeviceType || null,
      credentialBackedUp ? 1 : 0,
      normalizeLabel(label, `Security key ${existingCount + 1}`),
    );
  audit.record({ actorType: 'user', actorId: userId, affectedUserId: userId, action: 'security_key_registered' });
  return { credentials: listCredentials(userId) };
}

async function beginAuthentication({ account, rp }) {
  // With nothing registered anywhere the browser would sit on its key prompt
  // until the ceremony times out. This count covers the whole relying party, so
  // refusing early reveals nothing about any particular account.
  const registered = getDatabase()
    .prepare('SELECT COUNT(*) AS count FROM user_webauthn_credentials WHERE rp_id = ?')
    .get(rp.rpId).count;
  if (registered === 0) {
    throw new HttpError(409, 'NO_CREDENTIALS_REGISTERED', 'No security keys are registered for this server yet. Add one under Settings first.');
  }

  // Without an account hint the browser picks a discoverable credential itself,
  // so the allow-list stays empty and no account existence is revealed.
  let allowCredentials = [];
  const normalized = String(account || '').trim();
  if (normalized) {
    const user = getDatabase()
      .prepare('SELECT id FROM users WHERE username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE')
      .get(normalized, normalized);
    if (user) allowCredentials = credentialsForRelyingParty(user.id, rp.rpId);
  }
  const options = await generateAuthenticationOptions({
    rpID: rp.rpId,
    timeout: CEREMONY_TIMEOUT_MS,
    userVerification: 'preferred',
    allowCredentials,
  });
  return { challengeId: storeChallenge({ purpose: 'authentication', userId: null, challenge: options.challenge, rp }), options };
}

async function completeAuthentication({ challengeId, response, twoFactorCode, rp }, context = {}) {
  const challenge = consumeChallenge({ challengeId, purpose: 'authentication', rp });
  const db = getDatabase();
  const credentialId = String(response?.id || '').trim();
  const stored = credentialId
    ? db.prepare('SELECT * FROM user_webauthn_credentials WHERE credential_id = ? AND rp_id = ?').get(credentialId, rp.rpId)
    : null;
  if (!stored) {
    audit.record({ actorType: 'system', action: 'security_key_login_failed', ipAddress: context.ipAddress });
    throw new HttpError(401, 'UNKNOWN_CREDENTIAL', 'This security key is not registered.');
  }

  const userHandle = response?.response?.userHandle;
  if (userHandle && Buffer.from(fromBase64Url(userHandle)).toString('utf8') !== stored.user_id) {
    throw new HttpError(401, 'UNKNOWN_CREDENTIAL', 'This security key is not registered.');
  }

  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge: challenge.challenge,
      expectedOrigin: rp.origin,
      expectedRPID: rp.rpId,
      requireUserVerification: false,
      credential: {
        id: stored.credential_id,
        publicKey: fromBase64Url(stored.public_key),
        counter: Number(stored.counter || 0),
        transports: parseTransports(stored),
      },
    });
  } catch (error) {
    audit.record({ actorType: 'system', action: 'security_key_login_failed', ipAddress: context.ipAddress });
    throw new HttpError(401, 'CREDENTIAL_REJECTED', error.message || 'The security key could not be verified.');
  }
  if (!verification.verified) {
    throw new HttpError(401, 'CREDENTIAL_REJECTED', 'The security key could not be verified.');
  }

  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(stored.user_id);
  if (!user) throw new HttpError(401, 'UNKNOWN_CREDENTIAL', 'This security key is not registered.');
  if (user.disabled_at) throw new HttpError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');

  // A key that verified the user with a PIN or a fingerprint already carries
  // both factors, so it stands in for the authenticator code. A key that only
  // confirmed presence still has to pass the second factor.
  if (!verification.authenticationInfo.userVerified) {
    authService.verifySecondFactor(user.id, twoFactorCode);
  }

  db.prepare(`UPDATE user_webauthn_credentials
    SET counter = ?, last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`)
    .run(Number(verification.authenticationInfo.newCounter || 0), stored.id);
  db.prepare("UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(user.id);
  audit.record({ actorType: 'user', actorId: user.id, affectedUserId: user.id, action: 'security_key_login_succeeded', ipAddress: context.ipAddress });

  return { user: authService.publicUser(user), session: authService.createSession(user.id, context) };
}

function renameCredential(userId, credentialId, label) {
  const nextLabel = normalizeLabel(label, '');
  if (!nextLabel) throw new HttpError(400, 'INVALID_LABEL', 'A security key name is required.');
  const result = getDatabase()
    .prepare('UPDATE user_webauthn_credentials SET label = ? WHERE id = ? AND user_id = ?')
    .run(nextLabel, credentialId, userId);
  if (result.changes === 0) throw new HttpError(404, 'CREDENTIAL_NOT_FOUND', 'This security key does not exist.');
  return { credentials: listCredentials(userId) };
}

function deleteCredential(userId, credentialId) {
  const result = getDatabase()
    .prepare('DELETE FROM user_webauthn_credentials WHERE id = ? AND user_id = ?')
    .run(credentialId, userId);
  if (result.changes === 0) throw new HttpError(404, 'CREDENTIAL_NOT_FOUND', 'This security key does not exist.');
  audit.record({ actorType: 'user', actorId: userId, affectedUserId: userId, action: 'security_key_removed' });
  return { credentials: listCredentials(userId) };
}

module.exports = {
  beginAuthentication,
  beginRegistration,
  completeAuthentication,
  completeRegistration,
  deleteCredential,
  listCredentials,
  renameCredential,
  resolveRelyingParty,
};
