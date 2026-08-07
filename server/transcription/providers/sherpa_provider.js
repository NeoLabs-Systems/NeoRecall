'use strict';

const path = require('node:path');
const { TranscriptionProvider } = require('../transcription_provider');
const { paths } = require('../../../runtime/paths');
const { installedMatchesManifest } = require('../../../lib/model_downloader');
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

/// Whisper's encoder has a fixed 30-second context; sherpa-onnx silently
/// truncates and discards anything past it in a single decode call. VAD spans
/// are usually well under that, but an uninterrupted monologue can exceed it,
/// so long spans are hard-cut into 30-second windows before decoding.
const WHISPER_WINDOW_SAMPLES = 30 * 16000;
function windowForWhisper(span) {
  if (span.samples.length <= WHISPER_WINDOW_SAMPLES) return [span];
  const windows = [];
  for (let offset = 0; offset < span.samples.length; offset += WHISPER_WINDOW_SAMPLES) {
    windows.push({ startSample: span.startSample + offset, samples: span.samples.subarray(offset, offset + WHISPER_WINDOW_SAMPLES) });
  }
  return windows;
}

class SherpaProvider extends TranscriptionProvider {
  constructor() { super(); this.recognizer = null; }
  /// The model files this provider needs, as manifest-relative paths.
  ///
  /// Relative rather than absolute so each one can be checked against what the
  /// manifest pins, not merely for existence. A directory left behind by an
  /// earlier model generation has all the right filenames and none of the right
  /// contents, and that has to read as "not ready" rather than as ready.
  requiredPaths() {
    const files = [
      ...['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt'].map((name) => `asr/${name}`),
      'vad/silero_vad.onnx',
    ];
    if (getConfig().diarizationEnabled) files.push(
      'diarization/pyannote-segmentation-3.0.int8.onnx',
      'diarization/wespeaker_en_voxceleb_CAM++_LM.onnx',
    );
    return files;
  }
  requiredFiles() { return this.requiredPaths().map((relative) => path.join(paths().models, relative)); }
  installed() {
    return this.requiredPaths().every((relative) => installedMatchesManifest(relative, path.join(paths().models, relative)));
  }
  async ready() { return this.installed(); }
  getRecognizer() {
    if (!this.installed()) {
      throw Object.assign(new Error('The local speech models are missing or are not the ones this version pins. Run `neorecall setup`.'), { code: 'TRANSCRIPTION_MODELS_MISSING' });
    }
    if (!this.recognizer) {
      const { OfflineRecognizer } = require('sherpa-onnx-node');
      const directory = path.join(paths().models, 'asr');
      // featureDim is read from the encoder's own ONNX metadata (128 mel bins for
      // large-v3) and this value is ignored on the whisper decode path; sampleRate
      // is the only field that matters here.
      this.recognizer = new OfflineRecognizer({ featConfig: { sampleRate: 16000, featureDim: 80 }, modelConfig: {
        whisper: { encoder: path.join(directory, 'encoder.int8.onnx'), decoder: path.join(directory, 'decoder.int8.onnx'), task: 'transcribe' },
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
      const speech = vad.speechSegments(component.samples).flatMap(windowForWhisper);
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
