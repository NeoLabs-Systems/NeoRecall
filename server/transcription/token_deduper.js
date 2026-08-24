'use strict';

function tokens(value) {
  return [...new Intl.Segmenter(undefined, { granularity: 'word' }).segment(String(value).normalize('NFKC').toLocaleLowerCase())]
    .filter((part) => part.isWordLike).map((part) => part.segment);
}

function similarity(left, right) {
  const a = tokens(left); const b = tokens(right);
  if (!a.length || !b.length) return 0;
  const rows = Array.from({ length: a.length + 1 }, () => new Uint16Array(b.length + 1));
  for (let i = 1; i <= a.length; i += 1) for (let j = 1; j <= b.length; j += 1) rows[i][j] = a[i - 1] === b[j - 1] ? rows[i - 1][j - 1] + 1 : Math.max(rows[i - 1][j], rows[i][j - 1]);
  return rows[a.length][b.length] / Math.max(a.length, b.length);
}

// Cross-device suppression is intentionally stricter than overlap cleanup
// inside one recorder. Independent devices may hear unrelated audio at the
// same time, so only a complete, exact multi-word utterance is proof enough to
// discard the redundant transcript copy. Punctuation, casing and Unicode
// presentation forms do not make spoken words different.
function exactSameUtterance(left, right, minimumWords = 2) {
  if (!Number.isInteger(minimumWords) || minimumWords < 2) {
    throw new Error('Cross-stream dedupe requires at least two exact words.');
  }
  const a = tokens(left); const b = tokens(right);
  return a.length >= minimumWords && a.length === b.length && a.every((word, index) => word === b[index]);
}

function dedupeExactCrossStream(segments, candidates, { timeToleranceMs, minimumWords = 2 }) {
  if (!Number.isFinite(timeToleranceMs) || timeToleranceMs < 0) {
    throw new Error('Cross-stream timestamp tolerance must come from validated configuration.');
  }
  return segments.filter((segment) => !candidates.some((candidate) => {
    const overlaps = segment.startMs < candidate.endMs && candidate.startMs < segment.endMs;
    return overlaps
      && Math.abs(candidate.startMs - segment.startMs) <= timeToleranceMs
      && Math.abs(candidate.endMs - segment.endMs) <= timeToleranceMs
      && exactSameUtterance(candidate.text, segment.text, minimumWords);
  }));
}

function dedupe(segments, previousSegments, { similarityThreshold, timeToleranceMs }) {
  if (!Number.isFinite(similarityThreshold) || !Number.isFinite(timeToleranceMs)) throw new Error('Dedupe thresholds must come from validated configuration.');
  const accepted = [];
  for (const segment of [...segments].sort((a, b) => a.startMs - b.startMs)) {
    const duplicate = [...previousSegments, ...accepted].find((candidate) =>
      Math.abs(candidate.startMs - segment.startMs) <= timeToleranceMs &&
      Math.abs(candidate.endMs - segment.endMs) <= timeToleranceMs && similarity(candidate.text, segment.text) >= similarityThreshold);
    if (!duplicate) accepted.push(segment);
    else if ((segment.asrConfidence || 0) > (duplicate.asrConfidence || 0) && accepted.includes(duplicate)) accepted.splice(accepted.indexOf(duplicate), 1, segment);
  }
  return accepted;
}

module.exports = { tokens, similarity, exactSameUtterance, dedupeExactCrossStream, dedupe };
