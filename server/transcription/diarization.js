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
    clustering: { numClusters: -1, threshold: config.diarizationClusterDistance },
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

// One fingerprint per voice per chunk, pooled from everything that voice said
// in it, weighted by turn duration so a longer turn counts for more.
function poolBySpeaker(turns) {
  const bySpeaker = new Map();
  for (const turn of turns) {
    if (!turn.embedding) continue;
    if (!bySpeaker.has(turn.speaker)) bySpeaker.set(turn.speaker, []);
    bySpeaker.get(turn.speaker).push(turn);
  }
  const pooled = new Map();
  for (const [speaker, list] of bySpeaker) {
    const dimensions = list[0].embedding.length;
    const total = new Float32Array(dimensions);
    let weight = 0;
    for (const turn of list) {
      const duration = Math.max(1, turn.endMs - turn.startMs);
      weight += duration;
      for (let index = 0; index < dimensions; index += 1) total[index] += turn.embedding[index] * duration;
    }
    for (let index = 0; index < dimensions; index += 1) total[index] /= weight;
    pooled.set(speaker, { embedding: total, speechMs: weight });
  }
  return pooled;
}

function diarize(samples) {
  if (!getConfig().diarizationEnabled) return [];
  const { diarizer: model } = getModels();
  const turns = model.process(samples).map((turn) => ({
    startMs: Math.round(turn.start * 1000), endMs: Math.round(turn.end * 1000), speaker: turn.speaker,
    embedding: embeddingForSpan(samples, turn.start, turn.end),
  }));
  const pooled = poolBySpeaker(turns);
  return turns.map((turn) => {
    const voice = pooled.get(turn.speaker);
    return voice
      // speechMs is how much speech the fingerprint was built from, which is what
      // decides whether it is trustworthy — not the length of this one turn.
      ? { ...turn, embedding: voice.embedding, speechMs: voice.speechMs }
      : { ...turn, speechMs: 0 };
  });
}

module.exports = { diarize, embeddingForSpan, poolBySpeaker };
