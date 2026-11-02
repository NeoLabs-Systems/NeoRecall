'use strict';

const providerSettings = require('./provider_settings_service');
const registry = require('../../local_runtime/registry');
const { HttpError } = require('../../middleware/error_handler');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('local-models');

// Every provider in either catalog that runs on this server, with the workload
// it serves.
function localProviders() {
  const entries = [];
  for (const [workload, catalog] of [['transcription', providerSettings.TRANSCRIPTION_PROVIDERS], ['llm', providerSettings.LLM_PROVIDERS]]) {
    for (const [provider, definition] of Object.entries(catalog)) {
      if (definition.local) entries.push({ workload, provider, component: definition.component });
    }
  }
  return entries;
}

function isSelected(entry) {
  return providerSettings.getRuntime()[entry.workload].provider === entry.provider;
}

// What the Admin screen shows about each on-host model. `selected` says whether
// that workload is currently pointed at it, which is independent of whether it is
// installed: an admin can fetch a model ahead of switching to it.
function status() {
  return localProviders().map((entry) => ({
    ...registry.installerFor(entry.component).status(), workload: entry.workload, provider: entry.provider, selected: isSelected(entry),
  }));
}

// Begins installing in the background and returns the status as it stands. The
// install is resumable and guarded by a lock, so calling this when one is already
// running, or from both server processes at once, is harmless.
function install(componentId, { force = false } = {}) {
  if (!localProviders().some((entry) => entry.component === componentId)) throw new HttpError(404, 'LOCAL_MODEL_NOT_FOUND', 'Unknown local model.');
  registry.installerFor(componentId).ensureInstalled({ force });
  return status().find((item) => item.id === componentId);
}

// Called when the configuration changes and when the server starts, so that
// choosing a local provider — or restarting in the middle of its download —
// leads to an installed model without anyone pressing a button.
function resumeSelected() {
  for (const entry of localProviders()) {
    try {
      const installer = registry.installerFor(entry.component);
      if (isSelected(entry) && installer.supported) installer.ensureInstalled();
    } catch (error) {
      logger.warn('Could not resume installing a local model', { component: entry.component, reason: error.message });
    }
  }
}

module.exports = { status, install, resumeSelected, localProviders, isSelected };
