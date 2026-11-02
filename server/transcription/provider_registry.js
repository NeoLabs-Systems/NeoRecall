'use strict';

const providerSettings = require('../services/settings/provider_settings_service');
let instance;
let instanceProvider;

function getProvider() {
  const settings = providerSettings.getRuntime().transcription;
  if (instance && instanceProvider === settings.provider) return instance;
  // A provider that owns a process (the local one) must not outlive being
  // switched away from.
  Promise.resolve(instance?.dispose?.()).catch(() => {});
  if (settings.protocol === 'openai') instance = new (require('./providers/openai_compatible_provider').OpenAICompatibleProvider)();
  else if (settings.protocol === 'deepgram') instance = new (require('./providers/deepgram_provider').DeepgramProvider)();
  else if (settings.protocol === 'local') instance = new (require('./providers/whistle_provider').WhistleProvider)();
  else if (settings.protocol === 'assemblyai') instance = new (require('./providers/assemblyai_provider').AssemblyAIProvider)();
  else throw new Error(`Unsupported TRANSCRIPTION_PROVIDER: ${settings.provider}.`);
  instanceProvider = settings.provider;
  return instance;
}

function resetForTests() { instance = undefined; instanceProvider = undefined; }
module.exports = { getProvider, resetForTests };
