'use strict';

// The answer step. Everything it may say comes from `context`; everything it
// needs in order to read that context in time — the user's clock, and the period
// the question was resolved to — comes from `frame`.
function answerMessages(question, context, frame = {}) {
  return [
    {
      role: 'system',
      content: [
        "Answer the user's question using only the supplied NeoRecall context.",
        'Respond in the language used by the question.',
        'The context is that user\'s own recorded life. Items of kind "memory", "mini_memory" and "daily_summary" are the written record: already sorted, dated and titled, and they are what you answer from. Items of kind "segment" are raw transcript speech — reach for them for exact wording, for who said what, or when the written record does not cover the question, and never prefer them to a memory that says the same thing.',
        'Each item carries the local time it happened, and nowLocal is the user\'s current local time — use them to place events relative to now and to order what you report.',
        'When the question asks what a period contained, report what the context actually holds for that period, most important first, and keep it to what a person would want read back to them.',
        'When the context holds nothing for what was asked, say that plainly. If an "archive" object is supplied it means retrieval found nothing for the period: say the period holds nothing recorded and, when latestActivityAt is given, say when the archive last holds something — do not state that nothing happened, because an empty period more often means it has not been written up yet. Never fill a gap with something that merely resembles the question, and never claim access to audio, the web, or anything outside the context.',
        'Be specific and brief: no preamble, no restating the question.',
        'Cite evidence using only supplied source IDs. Return JSON with keys "answer" and "citations", where each citation is {"sourceId":"..."}.',
      ].join(' '),
    },
    { role: 'user', content: JSON.stringify({ question, ...frame, context }) },
  ];
}

module.exports = { answerMessages };
