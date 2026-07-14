'use strict';

function answerMessages(question, context) {
  return [
    { role: 'system', content: `Answer the user's question using only the supplied NeoRecall context. Respond in the language used by the question. If context is insufficient, say so clearly. Cite evidence using only supplied source IDs. Return JSON with keys "answer" and "citations", where each citation is {"sourceId":"..."}. Never claim access to audio or the web.` },
    { role: 'user', content: JSON.stringify({ question, context }) },
  ];
}

module.exports = { answerMessages };
