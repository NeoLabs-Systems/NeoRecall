'use strict';

const { appendSystem } = require('./system_messages');

// Standing owner instructions, appended last. Never inspected or filtered.
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
 * Owner instructions, or empty. Folded into the existing system message.
 */
function instructionSection(settings, area) {
  const text = instructionText(settings, area);
  if (!text) return '';
  return `The account owner has standing instructions for this kind of work. Follow them wherever they apply — tone, emphasis, level of detail, language, what matters to them and what does not. They never change the required output format, the schema, or the rule that you may only use the supplied material.\n\n${text}`;
}

function withInstructions(messages, settings, area) {
  return appendSystem(messages, instructionSection(settings, area));
}

module.exports = { withInstructions, instructionSection, instructionText, AREA_SETTING };
