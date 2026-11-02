'use strict';

// The installable components, by manifest id. Required lazily so that asking
// about one does not load the others.
const INSTALLERS = Object.freeze({
  whistle: () => require('../transcription/local_asr').getInstaller(),
  'gemma-2-2b-it': () => require('../ai/local_llm').getInstaller(),
});

function installerFor(componentId) {
  const factory = INSTALLERS[componentId];
  if (!factory) throw new Error(`Unknown local component: ${componentId}`);
  return factory();
}

module.exports = { installerFor, componentIds: () => Object.keys(INSTALLERS) };
