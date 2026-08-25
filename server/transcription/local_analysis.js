'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { paths } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { createLogger } = require('../utils/logger');

const logger = createLogger('local-analysis');

/// What NeoRecall still listens to the audio for, now that it no longer
/// transcribes it.
///
/// A transcription service returns words. It cannot return the one thing that
/// makes a voice the same person an hour later: a fingerprint of that voice.
/// The best it offers is a speaker label valid inside the single request that
/// produced it, and since every chunk is its own request, such a label cannot be
/// carried across a chunk boundary. So the two models that answer "who is
/// speaking, and when" stay here, where the audio already is.
///
/// They are small enough for that to be uncontroversial — a 640 KB voice-activity
/// detector and 31 MB of segmentation and speaker-embedding weights, against the
/// gigabytes recognition and generation would need — and they earn their place
/// twice over: silence never reaches the transcription service at all, which on a
/// recorder that runs all day is most of the day.

const REQUIRED_FILES = Object.freeze([
  'vad/silero_vad.onnx',
  'diarization/pyannote-segmentation-3.0.int8.onnx',
  'diarization/wespeaker_en_voxceleb_CAM++_LM.onnx',
]);

let warned = false;

/// Whether the audio models can actually run here.
///
/// Both halves are genuinely optional. `sherpa-onnx-node` ships prebuilt
/// binaries for the common platforms and is declared an optional dependency, so
/// an install on a platform it does not cover simply has no native module; and
/// an operator may deliberately skip the model download. Neither may break
/// transcription — they only decide whether a transcript arrives with speaker
/// identity attached, so the answer is cached per call rather than asserted at
/// startup.
function available() {
  if (!getConfig().diarizationEnabled) return false;
  if (!REQUIRED_FILES.every((relative) => fs.existsSync(path.join(paths().models, relative)))) {
    if (!warned) {
      warned = true;
      logger.warn('Speech-detection and diarization models are not installed; transcripts will carry no speaker identity. Run `neorecall setup`.');
    }
    return false;
  }
  try {
    require.resolve('sherpa-onnx-node');
    return true;
  } catch {
    if (!warned) {
      warned = true;
      logger.warn('The native audio runtime is unavailable on this platform; transcripts will carry no speaker identity.');
    }
    return false;
  }
}

/// Reads the chunk once, as a mono mixdown.
///
/// Mono on purpose, whatever the recording's channel layout: the transcription
/// service is sent the file as it is and returns one stream of segments over one
/// timeline, so the speaker turns those segments are matched against have to be
/// on that same timeline. Diarizing each channel separately would produce turns
/// no transcript segment could be aligned to.
function decodeMono(filename) {
  return require('./audio_decode').decodeAudio(filename, 'mono')[0].samples;
}

/// Whether this chunk contains speech worth paying to transcribe.
///
/// Returned separately from the turns because it gates the request itself. A
/// false negative here loses speech, so the threshold is configurable and the
/// bar is deliberately the detector's own: this is the same gate the pipeline
/// applied when recognition ran locally, and it is the reason an idle microphone
/// costs nothing.
function analyze(filename) {
  if (!available()) return { analyzed: false, hasSpeech: true, turns: [] };
  const samples = decodeMono(filename);
  const speech = require('./vad').speechSegments(samples);
  if (!speech.length) return { analyzed: true, hasSpeech: false, turns: [] };
  return { analyzed: true, hasSpeech: true, turns: require('./diarization').diarize(samples) };
}

module.exports = { available, analyze, decodeMono, REQUIRED_FILES };
