'use strict';

const { getConfig } = require('../config');

// What the configured language model can hold. Every provider is an external
// service, so the operator states it (LLM_CONTEXT_SIZE and the output budgets).
function contextSize() {
  return getConfig().llmContextSize;
}

function consolidationOutputTokens() {
  return getConfig().aiConsolidationMaxOutputTokens;
}

function previewOutputTokens() {
  return getConfig().aiPreviewMaxOutputTokens;
}

// Characters of transcript one consolidation request may read.
function consolidationWindowCharacters() {
  return getConfig().consolidationWindowCharacters;
}

module.exports = { contextSize, consolidationOutputTokens, previewOutputTokens, consolidationWindowCharacters };
