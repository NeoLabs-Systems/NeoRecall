'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { ensureRuntimeDirs } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { channelCount } = require('./audio_decode');
const { createLogger } = require('../utils/logger');

const logger = createLogger('audio-preprocess');

// Conditioning a chunk before anything listens to it.
//
// Recordings reach this server from pocket wearables with millimetre
// microphones, from meeting bots, from Discord and from files a person
// imported, and they arrive tens of decibels apart with whatever rumble and
// hiss the room contributed. A transcription service hears all of that. What
// runs here is ordinary signal processing — a high-pass, gentle spectral
// denoising, level normalization, a limiter — chosen because none of it knows
// or cares which language is being spoken.
//
// Two properties hold this together and are worth stating before the code:
//
// Every stage is sample-count and channel-count exact. Diarization turns,
// transcript timestamps and the speaker previews later cut from the *original*
// chunk all describe one timeline; a filter that dropped or added a sample
// would slide them apart with nothing to notice it. That is why there is no
// trimming, no gating, no tempo change here, and why the limiter compensates
// its own lookahead. A new stage is only admissible if it answers "yes" to: is
// it sample-exact?
//
// And it never fails a chunk. Every error path returns the original file, so
// the worst outcome of this whole module is exactly the behaviour that existed
// before it.

const NORMALIZERS = Object.freeze({
  off: () => null,
  // Cheap, and gentle by construction: gain moves slowly across a Gaussian
  // window rather than per frame, so speech does not pump. n=1 couples the
  // channels, which is what keeps the microphone/system level relationship in a
  // two-channel capture intact; without it each channel would be levelled on
  // its own and the roles would stop being comparable.
  dynaudnorm: (config) => ({
    filter: 'dynaudnorm',
    spec: `dynaudnorm=f=200:g=15:p=0.9:m=${config.audioPreprocessMaxGain}:t=0.02:n=1`,
  }),
  // Broadcast-correct loudness, and the only mode that reports what it measured.
  // It upsamples internally for true-peak detection, which costs roughly ten
  // times the rest of the chain put together.
  loudnorm: (config) => ({
    filter: 'loudnorm',
    spec: `loudnorm=I=${config.audioPreprocessTargetLufs}:TP=${config.audioPreprocessTruePeakDb}:LRA=11:print_format=json`,
  }),
  // Aggressive, and it lifts the noise floor between words along with the
  // speech. l=1 links the channels for the same reason dynaudnorm uses n=1.
  speechnorm: (config) => ({
    filter: 'speechnorm',
    spec: `speechnorm=e=${config.audioPreprocessMaxGain}:r=0.0001:l=1`,
  }),
});

// The chain, in order. Adding, removing or reordering a stage is one line.
const STAGES = Object.freeze([
  {
    name: 'highpass',
    build: (config) => config.audioPreprocessHighpassHz > 0 && {
      filter: 'highpass',
      spec: `highpass=f=${config.audioPreprocessHighpassHz}:p=2`,
    },
  },
  {
    name: 'denoise',
    build: (config) => config.audioPreprocessDenoiseEnabled && {
      filter: 'afftdn',
      spec: `afftdn=nr=${config.audioPreprocessDenoiseDb}:nf=${config.audioPreprocessDenoiseFloorDb}:tn=1`,
    },
  },
  {
    name: 'normalize',
    build: (config) => NORMALIZERS[config.audioPreprocessNormalizer]?.(config),
  },
  {
    name: 'limiter',
    // level=false matters more than it looks: alimiter's auto-level defaults to
    // true and would raise everything back to full scale, undoing the ceiling
    // this stage exists to impose. latency=true compensates the lookahead so no
    // offset enters the timeline.
    build: (config) => config.audioPreprocessLimiterEnabled && {
      filter: 'alimiter',
      spec: `alimiter=limit=${config.audioPreprocessLimiterPeak}:level=false:latency=true`,
    },
  },
]);

let warned = false;
let probedFilters;

function warnOnce(message, details) {
  if (warned) return;
  warned = true;
  logger.warn(message, details);
}

// Which filters this platform's ffmpeg build actually carries, asked once. The
// binary ships with the package and has always carried all of these, so this is
// insurance rather than a real branch: a stripped build loses one stage instead
// of failing every chunk.
function availableFilters() {
  if (probedFilters) return probedFilters;
  probedFilters = new Set();
  try {
    const result = spawnSync(ffmpegPath, ['-hide_banner', '-filters'], { encoding: 'utf8', timeout: 10_000 });
    for (const line of String(result.stdout || '').split('\n')) {
      const match = line.match(/^\s*[A-Z.]+\s+(\S+)\s/);
      if (match) probedFilters.add(match[1]);
    }
  } catch (error) {
    logger.warn('Could not list the available audio filters; conditioning will be attempted anyway', { error });
  }
  // An empty probe means the question could not be answered, not that the
  // answer is "none" — let ffmpeg itself be the judge in that case.
  if (!probedFilters.size) probedFilters = null;
  return probedFilters;
}

// The filter chain for a configuration, as { applied, chain }. Pure: `supported`
// is passed in rather than probed, so the composition can be asserted without
// running anything.
function buildFilters(config, supported = null) {
  const applied = [];
  const chain = [];
  for (const stage of STAGES) {
    const built = stage.build(config);
    if (!built) continue;
    if (supported && !supported.has(built.filter)) {
      logger.warn('Skipping an audio conditioning stage this ffmpeg build does not provide', { stage: stage.name, filter: built.filter });
      continue;
    }
    applied.push(stage.name);
    chain.push(built.spec);
  }
  return { applied, chain };
}

// Runtime overrides on top of the environment, so the chain can be softened or
// switched off without restarting a worker. The database is not reachable from
// every context this module can be loaded in, and a missing override is never a
// reason to skip conditioning.
function effectiveConfig() {
  const base = getConfig();
  try {
    return { ...base, ...require('../services/settings/processing_settings_service').get() };
  } catch (_) {
    return base;
  }
}

const inFlight = new Set();
let exitHookInstalled = false;

function installExitHook() {
  if (exitHookInstalled) return;
  exitHookInstalled = true;
  process.on('exit', () => {
    for (const file of inFlight) {
      try { fs.unlinkSync(file); } catch (_) { /* the sweep is the backstop */ }
    }
  });
}

function workPath(format) {
  return path.join(ensureRuntimeDirs().audioWork, `${crypto.randomUUID()}.${format}`);
}

function remove(file) {
  inFlight.delete(file);
  try { fs.unlinkSync(file); } catch (error) {
    if (error.code !== 'ENOENT') logger.warn('Could not remove conditioned audio', { errorCode: 'AUDIO_PREPROCESS_CLEANUP_FAILED', error });
  }
}

// loudnorm reports what it measured on stderr. Nothing else does, so these are
// null for every other normalizer rather than being measured separately — a
// second pass over the audio to log two numbers is not worth its cost.
function measuredLoudness(stderr) {
  const match = String(stderr || '').match(/\{[^{}]*"input_i"[\s\S]*?\}/);
  if (!match) return { inputLufs: null, outputLufs: null };
  try {
    const parsed = JSON.parse(match[0]);
    return { inputLufs: Number(parsed.input_i), outputLufs: Number(parsed.output_i) };
  } catch (_) {
    return { inputLufs: null, outputLufs: null };
  }
}

// Whether conditioning would do anything at all, for callers that want to know
// before asking for it. prepare() answers the same question itself.
function available() {
  const config = effectiveConfig();
  if (!config.audioPreprocessEnabled || !ffmpegPath) return false;
  return buildFilters(config, availableFilters()).chain.length > 0;
}

// Conditions one chunk and returns where to read it from.
//
// Always returns a usable result and never throws: when anything at all goes
// wrong the original filename comes back with `fellBack` set, which is the
// pipeline's behaviour before this module existed. The caller owns the returned
// cleanup() and must call it in a finally block — it is idempotent and safe on
// a passthrough result.
//
// spawnSync blocks, matching audio_decode and the speaker previews. The worker
// runs one job at a time, so that is a deliberate simplification rather than an
// oversight; it would become a head-of-line block if inference ever ran
// concurrently.
function prepare(filename, { channelLayout = 'mono', durationMs = null } = {}) {
  const passthrough = { filename, applied: [], seconds: 0, fellBack: false, inputLufs: null, outputLufs: null, cleanup: () => {} };
  const config = effectiveConfig();
  if (!config.audioPreprocessEnabled) return passthrough;
  if (!ffmpegPath) {
    warnOnce('No ffmpeg binary is available; audio is sent for transcription unconditioned.');
    return passthrough;
  }
  if (config.audioPreprocessMaxDurationMs && durationMs > config.audioPreprocessMaxDurationMs) {
    logger.info('Skipped audio conditioning for an unusually long recording', { durationMs, limitMs: config.audioPreprocessMaxDurationMs });
    return passthrough;
  }
  const { applied, chain } = buildFilters(config, availableFilters());
  // Nothing to apply means nothing to gain from re-encoding the chunk.
  if (!chain.length) return passthrough;

  let channels;
  try { channels = channelCount(channelLayout); } catch (error) {
    logger.warn('Skipped audio conditioning for an unknown channel layout', { channelLayout, error });
    return passthrough;
  }

  const output = workPath(config.audioPreprocessFormat);
  installExitHook();
  inFlight.add(output);
  const fellBack = (errorCode, details) => {
    remove(output);
    logger.warn('Audio conditioning failed; the original recording is used instead', { errorCode, ...details });
    return { ...passthrough, fellBack: true };
  };

  const startedAt = process.hrtime.bigint();
  const result = spawnSync(ffmpegPath, [
    '-hide_banner', '-nostdin',
    // loudnorm prints its measurements at info level; nothing else needs them.
    '-v', config.audioPreprocessNormalizer === 'loudnorm' ? 'info' : 'error',
    '-y',
    '-i', filename,
    '-vn', '-map', '0:a:0',
    '-af', chain.join(','),
    '-ar', String(config.audioPreprocessSampleRate),
    '-ac', String(channels),
    '-c:a', config.audioPreprocessFormat === 'flac' ? 'flac' : 'pcm_s16le',
    '-f', config.audioPreprocessFormat,
    output,
  ], { encoding: 'utf8', timeout: config.audioPreprocessTimeoutMs, killSignal: 'SIGKILL', windowsHide: true });

  const stderrTail = String(result.stderr || '').slice(-300);
  if (result.error?.code === 'ETIMEDOUT' || result.signal) {
    return fellBack('AUDIO_PREPROCESS_TIMEOUT', { timeoutMs: config.audioPreprocessTimeoutMs, signal: result.signal });
  }
  if (result.error) return fellBack('AUDIO_PREPROCESS_FAILED', { error: result.error });
  if (result.status !== 0) return fellBack('AUDIO_PREPROCESS_FAILED', { status: result.status, stderrTail });

  let size;
  try { size = fs.statSync(output).size; } catch (error) {
    return fellBack('AUDIO_PREPROCESS_EMPTY_OUTPUT', { error, stderrTail });
  }
  // A truncated result is more dangerous than no result: it would transcribe
  // and silently lose the end of the recording. For uncompressed output the
  // expected size is arithmetic, so a short file is provable rather than
  // guessed; FLAC is checked only for emptiness.
  const expected = durationMs && config.audioPreprocessFormat === 'wav'
    ? (durationMs / 1000) * config.audioPreprocessSampleRate * channels * 2
    : 0;
  if (size < 1024 || (expected && size < expected * 0.25)) {
    return fellBack('AUDIO_PREPROCESS_EMPTY_OUTPUT', { size, expectedBytes: Math.round(expected), stderrTail });
  }

  return {
    filename: output,
    applied,
    seconds: Number(process.hrtime.bigint() - startedAt) / 1e9,
    fellBack: false,
    ...measuredLoudness(result.stderr),
    cleanup: () => remove(output),
  };
}

module.exports = { available, prepare, buildFilters, STAGES, NORMALIZERS };
