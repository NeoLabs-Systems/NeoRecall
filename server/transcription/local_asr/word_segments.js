'use strict';

// A closing quote or bracket may follow the terminal mark: `done."` still ends
// the sentence. \p{Sentence_Terminal} is the Unicode property, not a word list.
const ENDS_SENTENCE = /\p{Sentence_Terminal}[\p{Pe}\p{Pf}"']*$/u;

// Groups Whistle's timestamped words into transcript segments.
//
// The model reports words, and everything downstream (speaker alignment,
// de-duplication, boundary detection) expects utterance-sized segments with
// their own times. A segment ends at a sentence-final mark, at a silence of
// `gapMs`, or at `maxMs`, whichever comes first. Smaller segments matter beyond
// tidiness: each one is joined to the speaker turn it overlaps most, so a
// segment spanning two speakers is attributed to only one of them.
//
// `offsetMs` places a window on the chunk's timeline. Times are rounded by the
// shared segment builder.
function wordsToSegments(words, { offsetMs = 0, language = null, gapMs, maxMs }) {
  const segments = [];
  let current = [];
  const flush = () => {
    if (!current.length) return;
    const confidences = current.map((word) => word.probability).filter(Number.isFinite);
    segments.push({
      text: current.map((word) => word.word).join(' '),
      language,
      startMs: offsetMs + current[0].start * 1000,
      endMs: offsetMs + current.at(-1).end * 1000,
      asrConfidence: confidences.length ? confidences.reduce((sum, value) => sum + value, 0) / confidences.length : null,
    });
    current = [];
  };
  for (const word of words) {
    if (typeof word?.word !== 'string' || !word.word.trim()) continue;
    const previous = current.at(-1);
    if (previous && ((word.start - previous.end) * 1000 >= gapMs || (word.end - current[0].start) * 1000 > maxMs)) flush();
    current.push(word);
    if (ENDS_SENTENCE.test(word.word)) flush();
  }
  flush();
  return segments;
}

module.exports = { wordsToSegments };
