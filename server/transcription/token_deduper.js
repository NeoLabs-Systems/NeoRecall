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

module.exports = { tokens, similarity, dedupe };
