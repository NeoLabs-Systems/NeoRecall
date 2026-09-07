'use strict';

function card(memory) {
  return {
    type: memory.type,
    titleEn: memory.title_en,
    summaryEn: memory.summary_en,
    startedAt: memory.started_at,
    endedAt: memory.ended_at,
    topics: memory.topics || [],
    highlights: (memory.miniMemories || []).map((mini) => mini.text_en),
  };
}

// Asks one question about two cards: do they describe the same sitting?
//
// The wording deliberately matches the continuation decision the consolidation
// prompt already makes, because it is the same question asked later. What
// differs is where it is asked from: continuation sees a transcript, this sees
// only two finished cards, so it is told to answer no when the cards do not
// settle it. A wrong no leaves a duplicate someone can merge by hand; a wrong
// yes destroys a distinct memory.
function dedupeMemoryMessages(left, right, { minutesApart, sameStream }) {
  return [
    {
      role: 'system',
      content: `You decide whether two saved memory cards describe the SAME real-world occasion — one sitting that was recorded in pieces — or two separate occasions.
Return one JSON object matching the supplied contract. Write reasoning first: one sentence naming the evidence. Then set sameOccasion.
The same occasion looks like: one continuous sitting split by a pause or a recording that stopped and restarted, the second card picking up mid-thread, minutes rather than hours apart, the same people and the same activity still under way.
Separate occasions look like: a fresh start, the material introduced again from the beginning, a different group, a different place or activity, or an explicit reference to the earlier one as something that already happened.
A shared subject, topic, course, project or recurring meeting is NOT evidence of one occasion. Two lessons of one course, two calls about one project and two meals on one day are separate occasions however alike they read.
Answer false whenever the two cards do not clearly show one sitting. A duplicate that survives can be merged by hand later; two genuinely different occasions merged into one cannot be taken apart.
Return no prose outside JSON.`,
    },
    {
      role: 'user',
      content: JSON.stringify({
        minutesApart,
        recordedInSameStream: sameStream,
        first: card(left),
        second: card(right),
        outputContract: {
          reasoning: 'one sentence naming the evidence',
          sameOccasion: false,
        },
      }),
    },
  ];
}

module.exports = { dedupeMemoryMessages };
