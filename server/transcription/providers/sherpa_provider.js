'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { TranscriptionProvider } = require('../transcription_provider');
const { paths } = require('../../../runtime/paths');
const { getConfig } = require('../../config');
const vad = require('../vad');
const diarization = require('../diarization');
const { alignSegments } = require('../speaker_alignment');
const { detect: detectLanguage } = require('tinyld');

/// Language of a transcript segment the recogniser did not label itself.
///
/// The statistical detector needs enough text to work with: on a short
/// utterance it still returns its best guess, and that guess is frequently
/// wrong — real recordings produce "Gentlemen." labelled Afrikaans and "Uh"
/// labelled Klingon. An unknown language is honest and harmless; a confidently
/// wrong one is a false statement that reaches both the interface and the
/// consolidation prompt. Below the configured length the answer is therefore
/// no answer.
function statisticalLanguage(text, minimumCharacters) {
  if (!text || text.length < minimumCharacters) return null;
  return detectLanguage(text) || null;
}

class SherpaProvider extends TranscriptionProvider {
  constructor() { super(); this.recognizer = null; }
  requiredFiles() {
    const files = [
      ...['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'].map((name) => path.join(paths().models, 'asr', name)),
      path.join(paths().models, 'vad', 'silero_vad.onnx'),
    ];
    if (getConfig().diarizationEnabled) files.push(
      path.join(paths().models, 'diarization', 'pyannote-segmentation-3.0.int8.onnx'),
      path.join(paths().models, 'diarization', 'wespeaker_en_voxceleb_CAM++_LM.onnx'),
    );
    return files;
  }
  async ready() { return this.requiredFiles().every((filename) => fs.existsSync(filename)); }
  getRecognizer() {
    if (!this.recognizer) {
      if (!this.requiredFiles().every((filename) => fs.existsSync(filename))) throw Object.assign(new Error('Local speech models are missing. Run `neorecall setup`.'), { code: 'TRANSCRIPTION_MODELS_MISSING' });
      const { OfflineRecognizer } = require('sherpa-onnx-node');
      const directory = path.join(paths().models, 'asr');
      this.recognizer = new OfflineRecognizer({ featConfig: { sampleRate: 16000, featureDim: 80 }, modelConfig: {
        transducer: { encoder: path.join(directory, 'encoder.int8.onnx'), decoder: path.join(directory, 'decoder.int8.onnx'), joiner: path.join(directory, 'joiner.int8.onnx') },
        tokens: path.join(directory, 'tokens.txt'), numThreads: getConfig().sherpaThreads, provider: 'cpu', debug: 0,
      } });
    }
    return this.recognizer;
  }
  transcribeSpeech(speech) {
    const recognizer = this.getRecognizer();
    const stream = recognizer.createStream();
    stream.acceptWaveform({ samples: speech.samples, sampleRate: 16000 });
    recognizer.decode(stream);
    const result = recognizer.getResult(stream);
    const text = String(result.text || '').trim();
    return { text, language: result.lang || statisticalLanguage(text, getConfig().languageDetectionMinimumCharacters), tokens: result.tokens || [],
      timestamps: result.timestamps || [], durations: result.durations || [], asrConfidence: null };
  }
  async transcribe({ components }) {
    const output = [];
    for (const component of components) {
      const turns = getConfig().diarizationEnabled ? diarization.diarize(component.samples) : [];
      const speech = vad.speechSegments(component.samples);
      const decoded = speech.map((span) => {
        const result = this.transcribeSpeech(span);
        const startMs = Math.round(span.startSample / 16);
        return { ...result, startMs, endMs: startMs + Math.round(span.samples.length / 16), sourceComponent: component.name };
      }).filter((segment) => segment.text);
      output.push(...alignSegments(decoded, turns));
    }
    return output.sort((left, right) => left.startMs - right.startMs);
  }
}

module.exports = { SherpaProvider, statisticalLanguage };
