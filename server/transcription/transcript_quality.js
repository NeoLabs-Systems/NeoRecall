'use strict';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });

function words(value) {
  const text = String(value || '').normalize('NFKC');
  return [...segmenter.segment(text)]
    .filter((part) => part.isWordLike)
    .map((part) => ({
      text: part.segment,
      index: part.index,
      // Counter-like hallucinations vary their number while retaining the same
      // surrounding template. Token classes cover that without vocabulary or a
      // phrase-based rule.
      comparable: /^\p{N}+$/u.test(part.segment)
        ? '<number>'
        : part.segment.toLocaleLowerCase(),
    }));
}

function samePattern(items, left, right, length) {
  for (let offset = 0; offset < length; offset += 1) {
    if (items[left + offset].comparable !== items[right + offset].comparable) return false;
  }
  return true;
}

function dominantRepeatedRun(items, { minimumRepeats, maximumPatternWords, minimumCoverage }) {
  let best = null;
  const maximumPattern = Math.min(maximumPatternWords, Math.floor(items.length / minimumRepeats));
  for (let patternWords = 1; patternWords <= maximumPattern; patternWords += 1) {
    for (let start = 0; start + (patternWords * minimumRepeats) <= items.length; start += 1) {
      let repeats = 1;
      while (start + ((repeats + 1) * patternWords) <= items.length
        && samePattern(items, start, start + (repeats * patternWords), patternWords)) repeats += 1;
      if (repeats < minimumRepeats) continue;
      const runWords = repeats * patternWords;
      const coverage = runWords / items.length;
      if (coverage < minimumCoverage) continue;
      if (!best || runWords > best.runWords || (runWords === best.runWords && patternWords < best.patternWords)) {
        best = { start, repeats, patternWords, runWords, coverage };
      }
    }
  }
  return best;
}

function validateOptions(options) {
  const values = [
    options.minimumRepeats,
    options.maximumPatternWords,
    options.minimumCoverage,
    options.maximumWordsPerSecond,
  ];
  if (values.some((value) => !Number.isFinite(value))) {
    throw new Error('Transcript quality thresholds must come from validated configuration.');
  }
}

function compactSegment(segment, options) {
  validateOptions(options);
  const text = String(segment.text || '').normalize('NFKC');
  const items = words(text);
  const durationSeconds = (Number(segment.endMs) - Number(segment.startMs)) / 1_000;
  if (!items.length || !Number.isFinite(durationSeconds) || durationSeconds <= 0
    || items.length / durationSeconds <= options.maximumWordsPerSecond) {
    return { segment, changed: false, removedWords: 0 };
  }

  const run = dominantRepeatedRun(items, options);
  if (!run) return { segment, changed: false, removedWords: 0 };

  const repeatedStart = items[run.start].index;
  const secondOccurrenceStart = items[run.start + run.patternWords].index;
  const runEndIndex = run.start + run.runWords;
  const repeatedEnd = runEndIndex < items.length ? items[runEndIndex].index : text.length;
  const firstOccurrence = text.slice(repeatedStart, secondOccurrenceStart);
  const compacted = `${text.slice(0, repeatedStart)}${firstOccurrence}${text.slice(repeatedEnd)}`.trim();
  return {
    segment: { ...segment, text: compacted },
    changed: true,
    removedWords: run.runWords - run.patternWords,
    repeats: run.repeats,
    patternWords: run.patternWords,
  };
}

function compactSegments(segments, settings) {
  const options = {
    minimumRepeats: settings.transcriptRepetitionMinimumRepeats,
    maximumPatternWords: settings.transcriptRepetitionMaximumPatternWords,
    minimumCoverage: settings.transcriptRepetitionMinimumCoverage,
    maximumWordsPerSecond: settings.transcriptMaximumWordsPerSecond,
  };
  const results = segments.map((segment) => compactSegment(segment, options));
  return {
    segments: results.map((result) => result.segment),
    changedSegments: results.filter((result) => result.changed).length,
    removedWords: results.reduce((total, result) => total + result.removedWords, 0),
  };
}

module.exports = { words, dominantRepeatedRun, compactSegment, compactSegments };
