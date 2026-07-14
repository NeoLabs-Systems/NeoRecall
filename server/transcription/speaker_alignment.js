'use strict';

function overlap(startA, endA, startB, endB) { return Math.max(0, Math.min(endA, endB) - Math.max(startA, startB)); }

function alignSegments(asrSegments, speakerTurns) {
  return asrSegments.map((segment) => {
    const ranked = speakerTurns.map((turn) => ({ turn, overlap: overlap(segment.startMs, segment.endMs, turn.startMs, turn.endMs) }))
      .filter((item) => item.overlap > 0).sort((left, right) => right.overlap - left.overlap);
    const best = ranked[0];
    const overlappingSpeech = ranked.length > 1 && ranked[1].overlap / Math.max(1, segment.endMs - segment.startMs) > 0.2;
    return { ...segment, diarizationSpeaker: best?.turn.speaker ?? null, speakerEmbedding: best?.turn.embedding || null,
      speakerConfidence: best ? best.overlap / Math.max(1, segment.endMs - segment.startMs) : null, overlappingSpeech };
  });
}

module.exports = { alignSegments, overlap };
