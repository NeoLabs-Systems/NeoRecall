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
        'The context is that user\'s own recorded life: transcript segments, memories written from them, and daily summaries. Each item carries the local time it happened, and nowLocal is the user\'s current local time — use them to place events relative to now and to order what you report.',
        'When the question asks what a period contained, report what the context actually holds for that period, most important first, and keep it to what a person would want read back to them.',
        'When the context holds nothing for what was asked, say that plainly and say what the archive does cover instead. Never fill a gap with something that merely resembles the question, and never claim access to audio, the web, or anything outside the context.',
        'Be specific and brief: no preamble, no restating the question.',
        'Cite evidence using only supplied source IDs. Return JSON with keys "answer" and "citations", where each citation is {"sourceId":"..."}.',
      ].join(' '),
    },
    { role: 'user', content: JSON.stringify({ question, ...frame, context }) },
  ];
}

module.exports = { answerMessages };
