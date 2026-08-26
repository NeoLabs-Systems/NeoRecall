'use strict';

const { getConfig, LLM_PROMPT_RESERVE_TOKENS } = require('../config');

// How much input one request may carry, in characters.
//
// A model that runs on this machine has a context window measured in tokens and
// paid for in memory, and everything that does not fit has to be split before
// the request is built rather than after it fails. The caller cannot count
// tokens without loading the model, so it asks for a character budget instead.
//
// The ratio is deliberately pessimistic. Compact transcript JSON carries
// identifiers, punctuation and non-English text, and tokenizes closer to three
// characters per token than to the four an English prose average would suggest.
// Over-estimating the budget produces a refusal after the work of building the
// request; under-estimating it produces one more window.
const CHARACTERS_PER_TOKEN = 3;

// The reserve is shared with the startup check in config.js, which refuses a
// context too small to hold both an output budget and a prompt — so by the time
// this runs there is always something left to spend.
function inputBudgetCharacters(maxOutputTokens) {
  const promptTokens = getConfig().llmContextSize - maxOutputTokens - LLM_PROMPT_RESERVE_TOKENS;
  return Math.max(1, promptTokens) * CHARACTERS_PER_TOKEN;
}

module.exports = { inputBudgetCharacters, CHARACTERS_PER_TOKEN };
