'use strict';

const { getConfig } = require('../config');
const providerSettings = require('../services/settings/provider_settings_service');

// What the configured language model can actually hold.
//
// For an external model the operator states it (LLM_CONTEXT_SIZE and the output
// budgets). A model that runs here has limits of its own, fixed by the model and
// written in the manifest, and a request sized for a larger one would simply not
// fit — so while a local model is selected its limits cap the configured ones.
// They only ever lower a budget: an operator who has set something smaller keeps
// it.
function localProfile() {
  const settings = providerSettings.getRuntime().llm;
  const definition = providerSettings.LLM_PROVIDERS[settings.provider];
  if (!definition?.local) return null;
  return require('../local_runtime/registry').installerFor(definition.component).entry.profile || null;
}

function capped(configured, limit) {
  return limit ? Math.min(configured, limit) : configured;
}

function contextSize() {
  return capped(getConfig().llmContextSize, localProfile()?.contextSize);
}

function consolidationOutputTokens() {
  return capped(getConfig().aiConsolidationMaxOutputTokens, localProfile()?.consolidationOutputTokens);
}

function previewOutputTokens() {
  return capped(getConfig().aiPreviewMaxOutputTokens, localProfile()?.previewOutputTokens);
}

// Characters of transcript one consolidation request may read. A small model does
// markedly better on a short window than on the default, so the profile lowers it.
function consolidationWindowCharacters() {
  return capped(getConfig().consolidationWindowCharacters, localProfile()?.consolidationWindowCharacters);
}

// Whether a window's answer is repaired piece by piece instead of being accepted
// or rejected whole. True for a model too small to honour the whole contract
// every time; see ai/repair_consolidation.
function tolerantOutput() {
  return Boolean(localProfile()?.tolerantOutput);
}

module.exports = { contextSize, consolidationOutputTokens, previewOutputTokens, consolidationWindowCharacters, tolerantOutput };
