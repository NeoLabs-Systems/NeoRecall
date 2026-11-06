'use strict';

const connection = require('./connection');
const providerSettings = require('../../services/settings/provider_settings_service');

// Which kinds of work go through the connected router. Summaries/chat ('llm')
// and speech to text ('transcription') are on exactly when that workload's
// provider is NeoRouter, so the switch and the provider selection can never
// disagree; 'embeddings' is its own setting on the connection.
const WORKLOAD = Object.freeze({ llm: 'llm', transcription: 'transcription' });
const AUTO_MODEL = 'auto';

function activeRoles() {
  if (!connection.get()) return [];
  const runtime = providerSettings.getRuntime();
  return connection.ROLES.filter((role) => (role === 'embeddings'
    ? connection.get().embeddings
    : runtime[WORKLOAD[role]].provider === connection.PROVIDER_ID));
}

function reindexSearch() {
  require('../../embeddings/search_index_service').reindexAll();
}

function setRole(role, on) {
  if (role === 'embeddings') {
    const was = connection.get()?.embeddings === true;
    connection.setEmbeddings(on);
    // Vectors of another model are not comparable; embed everything again.
    if (was !== on) reindexSearch();
    return;
  }
  const workload = WORKLOAD[role];
  const isRouter = providerSettings.getRuntime()[workload].provider === connection.PROVIDER_ID;
  if (on && !isRouter) providerSettings.update({ [workload]: { provider: connection.PROVIDER_ID, model: AUTO_MODEL } });
  // Back to what the server's own configuration says.
  else if (!on && isRouter) providerSettings.clearWorkloadOverride(workload);
}

/** Connecting turns every kind of work over to the router. */
function applyConnection({ apiBase, apiKey }) {
  connection.save({ apiBase, apiKey, embeddings: connection.get()?.embeddings === true });
  for (const role of connection.ROLES) setRole(role, true);
}

function updateRoles(wanted) {
  if (!connection.get()) throw Object.assign(new Error('NeoRouter is not connected.'), { code: 'NEOROUTER_NOT_CONNECTED' });
  const wantedSet = new Set(wanted);
  for (const role of connection.ROLES) setRole(role, wantedSet.has(role));
  return activeRoles();
}

function disconnect() {
  if (!connection.get()) return;
  for (const role of connection.ROLES) setRole(role, false);
  connection.clear();
}

module.exports = { activeRoles, applyConnection, disconnect, updateRoles };
