'use strict';

const SAMPLE_RATE = 16_000;
const FRAME_MS = 20;

// Whistle reads at most 30 s per pass, and a chunk can be longer than that. This
// decides where to cut it.
//
// A cut is placed at the quietest moment within `searchMs` before the window
// limit, so it lands in a pause rather than through a word. That is plain signal
// energy: it has no notion of language, and when there is no pause at all it
// degrades to a cut exactly at the limit, which is what a fixed split would have
// done anyway.
//
// Returns [{ startSample, endSample }] that tile the whole input with no gap and
// no overlap, so every window's timestamps add straight onto one timeline.
function planWindows(samples, { windowMs, searchMs, sampleRate = SAMPLE_RATE }) {
  const limit = Math.floor((windowMs / 1000) * sampleRate);
  const search = Math.min(Math.floor((searchMs / 1000) * sampleRate), limit - 1);
  const frame = Math.max(1, Math.floor((FRAME_MS / 1000) * sampleRate));
  const windows = [];
  let start = 0;
  while (samples.length - start > limit) {
    const end = quietestCut(samples, start + limit - search, start + limit, frame);
    windows.push({ startSample: start, endSample: end });
    start = end;
  }
  if (samples.length - start > 0) windows.push({ startSample: start, endSample: samples.length });
  return windows;
}

// The centre of the lowest-energy frame in [from, to]. Ties go to the later
// frame so windows stay as long as the limit allows.
function quietestCut(samples, from, to, frame) {
  let best = to;
  let bestEnergy = Infinity;
  for (let frameStart = from; frameStart + frame <= to; frameStart += frame) {
    let energy = 0;
    for (let index = frameStart; index < frameStart + frame; index += 1) energy += samples[index] * samples[index];
    if (energy <= bestEnergy) { bestEnergy = energy; best = frameStart + Math.floor(frame / 2); }
  }
  return best;
}

module.exports = { planWindows, SAMPLE_RATE };
