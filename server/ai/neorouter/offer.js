'use strict';

const crypto = require('node:crypto');
const { getConfig } = require('../../config');
const { modelList } = require('./client');

// What a NeoRouter can do for each role, from its own model lists: how many
// models it has, and how many more the key may not use. Shown next to the role
// switches. Auto models ("auto", "auto:fast", …) are listed separately: they
// are how NeoRouter picks the model per request.
const ROLE_TYPES = Object.freeze({ llm: 'chat', transcription: 'transcription', embeddings: 'embedding' });
const isAuto = (model) => /^auto(-(free|plan|paid))?(:|$)/.test(String(model.id));
const cache = new Map();

const cacheKey = (connection) => crypto.createHash('sha256').update(`${connection.apiBase}\n${connection.apiKey}`).digest('hex');

async function load(connection) {
  const roles = {};
  const notAllowed = {};
  await Promise.all(Object.entries(ROLE_TYPES).map(async ([role, type]) => {
    try {
      const list = await modelList(connection, type);
      roles[role] = { models: list.models.filter((model) => !isAuto(model)).length, auto: list.models.filter(isAuto).length };
      notAllowed[role] = (list.notAllowed.free || 0) + (list.notAllowed.plan || 0) + (list.notAllowed.paid || 0);
    } catch (error) {
      // A router that cannot be reached is the whole connection's problem; a
      // refused list (a key without this kind of work) is only this role's.
      if (error.code === 'NEOROUTER_UNREACHABLE') throw error;
      roles[role] = { models: 0, auto: 0, error: error.message };
      notAllowed[role] = 0;
    }
  }));
  return { roles, notAllowed };
}

/** { roles: { llm: { models, auto }, … }, notAllowed: { llm: n, … } }; throws when the router cannot be reached. */
async function describeOffer(connection, { fresh = false } = {}) {
  const key = cacheKey(connection);
  const cached = cache.get(key);
  if (!fresh && cached && cached.expiresAt > Date.now()) return cached.offer;
  const offer = await load(connection);
  cache.set(key, { offer, expiresAt: Date.now() + getConfig().neorouterOfferCacheMs });
  return offer;
}

module.exports = { describeOffer, isAuto, ROLE_TYPES };
