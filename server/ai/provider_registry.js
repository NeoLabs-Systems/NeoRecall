'use strict';

const providerSettings = require('../services/settings/provider_settings_service');

const PROVIDERS = Object.freeze({
  anthropic: './providers/anthropic_provider',
  openai: './providers/openai_compatible_provider',
});

function provider() {
  const settings = providerSettings.getRuntime().llm;
  const module = settings.protocol === 'anthropic' ? PROVIDERS.anthropic : PROVIDERS.openai;
  if (!module) throw new Error(`Unsupported AI_PROVIDER: ${settings.provider}.`);
  return require(module);
}

// Whether generation can be attempted at all.
//
// For a configured endpoint this means there is somewhere to send the request.
// Callers use it to
// decide whether to queue work rather than to let every job fail one by one.
function ready() {
  try { return provider().ready(); } catch { return false; }
}

module.exports = { provider, ready, PROVIDERS };
