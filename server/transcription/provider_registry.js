'use strict';

const { getConfig } = require('../config');
let instance;

function getProvider() {
  if (instance) return instance;
  if (getConfig().transcriptionProvider === 'sherpa') instance = new (require('./providers/sherpa_provider').SherpaProvider)();
  else if (getConfig().transcriptionProvider === 'openai-compatible') instance = new (require('./providers/openai_compatible_provider').OpenAICompatibleProvider)();
  else throw new Error(`Unsupported TRANSCRIPTION_PROVIDER: ${getConfig().transcriptionProvider}.`);
  return instance;
}

function resetForTests() { instance = undefined; }
module.exports = { getProvider, resetForTests };
