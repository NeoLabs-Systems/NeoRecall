'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { paths } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { createLogger } = require('../utils/logger');

const logger = createLogger('local-analysis');

// Local voice-activity detection and diarization: what NeoRecall still runs on
// the audio itself, since a transcription service returns words, not voices.

const REQUIRED_FILES = Object.freeze([
  'vad/silero_vad.onnx',
  'diarization/pyannote-segmentation-3.0.int8.onnx',
  'diarization/wespeaker_en_voxceleb_CAM++_LM.onnx',
]);

let warned = false;

// Whether the audio models can actually run here. Both the models and the
// native runtime are optional, so this is checked per call rather than asserted
// at startup.
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

// Reads the chunk once, as a mono mixdown, so diarization turns land on the
// same single timeline the transcription service's segments use.
function decodeMono(filename) {
  return require('./audio_decode').decodeAudio(filename, 'mono')[0].samples;
}

// Whether this chunk contains speech worth paying to transcribe.
function analyze(filename) {
  if (!available()) return { analyzed: false, hasSpeech: true, turns: [] };
  const samples = decodeMono(filename);
  const speech = require('./vad').speechSegments(samples);
  if (!speech.length) return { analyzed: true, hasSpeech: false, turns: [] };
  return { analyzed: true, hasSpeech: true, turns: require('./diarization').diarize(samples) };
}

module.exports = { available, analyze, decodeMono, REQUIRED_FILES };
