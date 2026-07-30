'use strict';

const crypto = require('crypto');
const sourcesService = require('./index');

// In-memory store for pairing tokens
// Key: token -> Value: { userId, name, targetUsers, createdAt, status }
const pairings = new Map();

// Tokens expire after 10 minutes
const EXPIRATION_MS = 10 * 60 * 1000;

function createPairing(userId, data) {
  // Clean up expired tokens
  const now = Date.now();
  for (const [key, val] of pairings.entries()) {
    if (now - val.createdAt > EXPIRATION_MS) {
      pairings.delete(key);
    }
  }

  const token = crypto.randomBytes(16).toString('hex');
  pairings.set(token, {
    userId,
    name: data.name,
    targetUsers: data.targetUsers,
    createdAt: now,
    status: 'pending' // pending -> success
  });

  return token;
}

function getPairingStatus(token) {
  const pairing = pairings.get(token);
  if (!pairing) return { status: 'expired' };
  return { status: pairing.status };
}

function consumePairing(token, discordToken) {
  const pairing = pairings.get(token);
  if (!pairing) {
    throw new Error('Invalid or expired pairing token');
  }

  // Create the actual source via sourcesService
  sourcesService.create(pairing.userId, {
    type: 'discord',
    name: pairing.name,
    enabled: true,
    config: {
      token: discordToken,
      targetUsers: pairing.targetUsers,
    }
  });

  // Mark as success so the UI knows it's done
  pairing.status = 'success';
  
  // We don't delete immediately so the UI can fetch the success status,
  // it will be cleaned up on the next expiration sweep.
  
  return true;
}

module.exports = {
  createPairing,
  getPairingStatus,
  consumePairing
};
