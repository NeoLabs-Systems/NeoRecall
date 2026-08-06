'use strict';

const { getConfig } = require('../config');

const PROVIDERS = Object.freeze({
  llama: './providers/llama_provider',
  openai_compatible: './providers/openai_compatible_provider',
});

function provider() {
  const name = getConfig().aiProvider;
  const module = PROVIDERS[name];
  if (!module) throw new Error(`Unsupported AI_PROVIDER: ${name}. Supported providers are ${Object.keys(PROVIDERS).join(' and ')}.`);
  return require(module);
}

/// Whether generation can be attempted at all.
///
/// For the local provider this means the weights are on disk; for a configured
/// endpoint it means there is somewhere to send the request. Callers use it to
/// decide whether to queue work rather than to let every job fail one by one.
function ready() {
  try { return provider().ready(); } catch { return false; }
}

module.exports = { provider, ready, PROVIDERS };
