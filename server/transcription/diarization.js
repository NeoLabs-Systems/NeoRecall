'use strict';

const path = require('node:path');
const { paths } = require('../../runtime/paths');
const { getConfig } = require('../config');

let diarizer;
let extractor;
function modelConfig() {
  const config = getConfig();
  const embeddingModel = path.join(paths().models, 'diarization', 'wespeaker_en_voxceleb_CAM++_LM.onnx');
  return {
    segmentation: { pyannote: { model: path.join(paths().models, 'diarization', 'pyannote-segmentation-3.0.int8.onnx') }, numThreads: config.sherpaThreads, provider: 'cpu', debug: 0 },
    embedding: { model: embeddingModel, numThreads: config.sherpaThreads, provider: 'cpu', debug: 0 },
    clustering: { numClusters: -1, threshold: config.speakerClusterThreshold },
    minDurationOn: config.diarizationMinimumOnSeconds, minDurationOff: config.diarizationMinimumOffSeconds,
  };
}

function getModels() {
  if (!diarizer || !extractor) {
    const sherpa = require('sherpa-onnx-node');
    const config = modelConfig();
    diarizer = new sherpa.OfflineSpeakerDiarization(config);
    extractor = new sherpa.SpeakerEmbeddingExtractor(config.embedding);
  }
  return { diarizer, extractor };
}

function embeddingForSpan(samples, startSeconds, endSeconds) {
  const { extractor: model } = getModels();
  const start = Math.max(0, Math.floor(startSeconds * 16000));
  const end = Math.min(samples.length, Math.ceil(endSeconds * 16000));
  const stream = model.createStream();
  stream.acceptWaveform({ samples: samples.slice(start, end), sampleRate: 16000 });
  if (!model.isReady(stream)) return null;
  return model.compute(stream, false);
}

function diarize(samples) {
  if (!getConfig().diarizationEnabled) return [];
  const { diarizer: model } = getModels();
  return model.process(samples).map((turn) => ({
    startMs: Math.round(turn.start * 1000), endMs: Math.round(turn.end * 1000), speaker: turn.speaker,
    embedding: embeddingForSpan(samples, turn.start, turn.end),
  }));
}

module.exports = { diarize, embeddingForSpan };
