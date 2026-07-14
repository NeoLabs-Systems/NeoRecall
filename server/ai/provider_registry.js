'use strict';

const { getConfig } = require('../config');

function provider() {
  const name = getConfig().aiProvider;
  if (name !== 'openrouter') throw new Error(`Unsupported AI_PROVIDER: ${name}. NeoRecall v1 supports OpenRouter only.`);
  return require('./providers/openrouter_provider');
}

module.exports = { provider };
