'use strict';

// Turns a question into a retrieval plan before anything is retrieved.
//
// Time is the reason this step exists. "What did I do today" carries no words
// worth matching against a transcript, so keyword and vector retrieval both
// return whatever vaguely resembles it — the question is about a period, and
// only a model that knows the user's current local time can say which one. The
// resolution is left to the model on purpose: a list of phrases to recognise
// would work in one language and fail in the next.
function planQueryMessages({ question, nowLocal, timezone }) {
  return [
    {
      role: 'system',
      content: [
        'You plan retrieval over a personal archive of transcripts, memories and daily summaries. You do not answer the question.',
        'Resolve every time expression in the question against the supplied current local time, and express the result as a half-open local range: fromLocal is inclusive, toLocal is exclusive, both "YYYY-MM-DDTHH:mm:ss" without an offset.',
        'Set both to null when the question is not about a time at all.',
        'Set wholePeriod to true when the question asks what a period contained, and false when it asks about a subject that merely happens to sit in one.',
        'searchQueries: between one and three restatements of what to look for, in the language of the question, keeping names and other proper nouns exactly as written. Drop the time words from them — the range already carries the time. For a wholePeriod question a single short restatement is enough.',
        'Leave kinds empty. Retrieval already reads the written record first and the raw transcript second; set kinds only when the question explicitly asks for one layer — verbatim wording or who said what ("segment"), or the day\'s own summary ("daily_summary") — and understand that doing so hides everything else from the answer.',
        'Return only the JSON object.',
      ].join(' '),
    },
    { role: 'user', content: JSON.stringify({ question, nowLocal, timezone }) },
  ];
}

module.exports = { planQueryMessages };
