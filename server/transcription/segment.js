'use strict';

// The shape every transcription provider must return, so downstream code
// (alignment, diarization, persistence) reads one contract rather than three.
const SEGMENT_DEFAULTS = Object.freeze({
  text: '',
  language: null,
  startMs: 0,
  endMs: 0,
  sourceComponent: 'combined',
  asrConfidence: null,
  diarizationSpeaker: null,
  speakerEmbedding: null,
  speakerConfidence: null,
  overlappingSpeech: false,
});

// Builds one segment, rounding the times and defaulting an absent end to the
// start — every provider needs both, and each had written them out by hand.
function buildSegment({ text, startMs = 0, endMs = null, ...rest }) {
  const start = Math.round(startMs || 0);
  return {
    ...SEGMENT_DEFAULTS,
    ...rest,
    text: String(text).trim(),
    startMs: start,
    endMs: Math.round(endMs ?? start),
  };
}

// Providers that report seconds rather than milliseconds.
function secondsToMs(value) { return (value || 0) * 1000; }

// Drops segments whose text is blank once trimmed. Every provider filtered
// these out separately, and a blank segment is never useful downstream.
function buildSegments(items) {
  return items.map(buildSegment).filter((segment) => segment.text);
}

module.exports = { buildSegment, buildSegments, secondsToMs, SEGMENT_DEFAULTS };
