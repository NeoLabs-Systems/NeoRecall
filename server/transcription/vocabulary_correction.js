'use strict';

const WORD = /[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*/gu;
const WHOLE_WORD = /^[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*$/u;

function normalized(value) { return value.normalize('NFKC').toLocaleLowerCase(); }

function editDistance(left, right) {
  if (left === right) return 0;
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
    const current = [leftIndex];
    for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
      current[rightIndex] = Math.min(
        current[rightIndex - 1] + 1,
        previous[rightIndex] + 1,
        previous[rightIndex - 1] + Number(left[leftIndex - 1] !== right[rightIndex - 1]),
      );
    }
    previous = current;
  }
  return previous[right.length];
}

function candidates(vocabulary, minimumLength) {
  return vocabulary.filter((term) => WHOLE_WORD.test(term)).map((term) => ({ term, normalized: normalized(term) }))
    .filter((entry) => [...entry.normalized].length >= minimumLength);
}

function correctText(text, vocabulary, options) {
  const entries = candidates(vocabulary, options.minimumLength);
  if (!entries.length) return text;
  return text.replace(WORD, (word) => {
    const source = normalized(word);
    if ([...source].length < options.minimumLength || entries.some((entry) => entry.normalized === source)) return word;
    const ranked = entries.filter((entry) => entry.normalized[0] === source[0]
        && Math.abs([...entry.normalized].length - [...source].length) <= options.maximumDistance)
      .map((entry) => {
        const distance = editDistance([...source], [...entry.normalized]);
        return { ...entry, distance, similarity: 1 - distance / Math.max([...source].length, [...entry.normalized].length) };
      }).filter((entry) => entry.distance <= options.maximumDistance && entry.similarity >= options.similarityThreshold)
      .sort((left, right) => right.similarity - left.similarity || left.distance - right.distance);
    const best = ranked[0];
    if (!best || (ranked[1] && best.similarity - ranked[1].similarity < options.ambiguityMargin)) return word;
    return best.term;
  });
}

function correctSegments(segments, vocabulary, options) {
  if (!vocabulary.length) return segments;
  return segments.map((segment) => ({ ...segment, text: correctText(segment.text, vocabulary, options) }));
}

module.exports = { editDistance, correctText, correctSegments };
