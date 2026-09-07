'use strict';

const { appendSystem } = require('./system_messages');

// Standing instructions the account owner wrote, carried into a request.
//
// They shape what the model emphasises, in which voice, at what length — the
// judgement calls this product otherwise makes on the user's behalf. They do
// not get to change the shape of the output: every caller here parses a schema
// and rejects what does not match it, so an instruction that asked for prose
// instead of JSON would only cost the user their consolidation run. Saying so
// in the message is what keeps that from happening.
//
// The text is never inspected, matched or filtered on the way through. It is
// one person's note to their own model about their own recordings.
const AREA_SETTING = Object.freeze({
  memories: 'instructionsMemories',
  summaries: 'instructionsSummaries',
  ask: 'instructionsAsk',
});

function instructionText(settings, area) {
  const global = String(settings?.instructionsGlobal || '').trim();
  const specific = String(settings?.[AREA_SETTING[area]] || '').trim();
  return [global, specific].filter(Boolean).join('\n\n');
}

/**
 * The account owner's instructions, worded for the model, or an empty string.
 *
 * Read last of everything the system message says, so it reads as a standing
 * preference on top of the task rather than as part of the material.
 */
function instructionSection(settings, area) {
  const text = instructionText(settings, area);
  if (!text) return '';
  return `The account owner has standing instructions for this kind of work. Follow them wherever they apply — tone, emphasis, level of detail, language, what matters to them and what does not. They never change the required output format, the schema, or the rule that you may only use the supplied material.\n\n${text}`;
}

/**
 * Folds the owner's instructions into a built message list's system message.
 *
 * Folded rather than added beside it: a second system message is rejected
 * outright by some chat templates — see `system_messages`.
 */
function withInstructions(messages, settings, area) {
  return appendSystem(messages, instructionSection(settings, area));
}

module.exports = { withInstructions, instructionSection, instructionText, AREA_SETTING };
