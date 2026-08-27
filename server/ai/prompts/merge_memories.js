'use strict';

const { MEMORY_TYPES } = require('../schemas/consolidation_schema');
const { TITLE_GUIDANCE } = require('./title_guidance');

function mergeMemoryMessages(memories) {
  const input = memories.map((memory, index) => ({
    id: `m${index + 1}`,
    type: memory.type,
    titleEn: memory.title_en,
    summaryEn: memory.summary_en,
    emoji: memory.emoji || null,
    startedAt: memory.started_at,
    endedAt: memory.ended_at,
    topics: memory.topics || [],
    highlights: (memory.miniMemories || []).map((mini) => ({
      kind: mini.kind,
      textEn: mini.text_en,
      status: mini.status || null,
    })),
  }));

  return [
    {
      role: 'system',
      content: `You merge several personal episodic memories into one coherent memory for a consumer app.
Return one JSON object matching the supplied contract. Title, summary and topics language must be English.
Write a single natural title and a faithful standalone summary that cover every important fact from the inputs without padding or inventing details.
${TITLE_GUIDANCE}
Prefer the most specific memory type from: ${MEMORY_TYPES.join('|')}.
Choose exactly one emoji that represents the combined occasion at a glance.
Do not mention that memories were merged. Do not list the source titles mechanically. Return no prose outside JSON.`,
    },
    {
      role: 'user',
      content: JSON.stringify({
        memories: input,
        outputContract: {
          type: MEMORY_TYPES.join('|'),
          titleEn: 'Concise English title for the combined occasion',
          summaryEn: 'Faithful English summary covering all important points',
          emoji: '🤝',
        },
      }),
    },
  ];
}

module.exports = { mergeMemoryMessages };
