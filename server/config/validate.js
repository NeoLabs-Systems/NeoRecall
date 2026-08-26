'use strict';

// Cross-field checks: settings that are each individually valid but cannot hold
// together. Caught at startup, where every one of these is a one-line fix,
// rather than as an exception on the first conversation of the day.
function validateConfig(config, { promptReserveTokens }) {
  if (config.speakerClusterContinuityThreshold > config.speakerClusterThreshold) {
    throw new Error('NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD must not exceed NEORECALL_SPEAKER_CLUSTER_THRESHOLD.');
  }
  if (config.conversationSoftGapMs >= config.conversationHardGapMs) {
    throw new Error('NEORECALL_CONVERSATION_SOFT_GAP_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS.');
  }
  if (config.conversationMinimumMs >= config.conversationHardGapMs) {
    throw new Error('NEORECALL_CONVERSATION_MINIMUM_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS.');
  }
  if (config.conversationMaximumMs <= config.conversationMinimumMs) {
    throw new Error('NEORECALL_CONVERSATION_MAXIMUM_MS must be longer than NEORECALL_CONVERSATION_MINIMUM_MS.');
  }
  if (config.conversationMaximumCharacters > config.maxConsolidationInputChars) {
    throw new Error('NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS must not exceed NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS.');
  }
  if (config.conversationPreviewMinCharacters > config.conversationMaximumCharacters) {
    throw new Error('NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS must not exceed NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS.');
  }
  // An output budget the context cannot also hold a prompt beside would leave
  // nothing to send. Caught at startup, where it is a one-line fix, rather than
  // as a scheduler exception on the first conversation of the day.
  for (const name of ['AI_CONSOLIDATION_MAX_OUTPUT_TOKENS', 'AI_PREVIEW_MAX_OUTPUT_TOKENS']) {
    const budget = name === 'AI_CONSOLIDATION_MAX_OUTPUT_TOKENS' ? config.aiConsolidationMaxOutputTokens : config.aiPreviewMaxOutputTokens;
    if (budget + promptReserveTokens >= config.llmContextSize) {
      throw new Error(`${name} (${budget}) leaves no room for input inside LLM_CONTEXT_SIZE (${config.llmContextSize}).`);
    }
  }
}

module.exports = { validateConfig };
