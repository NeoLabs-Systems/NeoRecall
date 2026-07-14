'use strict';

const path = require('node:path');
const { paths } = require('../../runtime/paths');
const { getConfig } = require('../config');

let model;
function getVad() {
  if (!model) {
    const { Vad } = require('sherpa-onnx-node');
    const config = getConfig();
    model = new Vad({ sileroVad: {
      model: path.join(paths().models, 'vad', 'silero_vad.onnx'), threshold: config.vadThreshold,
      minSilenceDuration: config.vadMinimumSilenceSeconds, minSpeechDuration: config.vadMinimumSpeechSeconds,
      windowSize: 512, maxSpeechDuration: config.chunkMaxMs / 1000,
    }, sampleRate: 16000, numThreads: config.sherpaThreads, provider: 'cpu', debug: 0 }, config.chunkMaxMs / 1000 + 5);
  }
  return model;
}

function speechSegments(samples) {
  const vad = getVad();
  vad.reset();
  const windowSize = 512;
  for (let offset = 0; offset < samples.length; offset += windowSize) {
    const frame = new Float32Array(windowSize);
    frame.set(samples.subarray(offset, Math.min(samples.length, offset + windowSize)));
    vad.acceptWaveform(frame);
  }
  vad.flush();
  const output = [];
  while (!vad.isEmpty()) {
    const segment = vad.front(false);
    output.push({ startSample: segment.start, samples: new Float32Array(segment.samples) });
    vad.pop();
  }
  return output;
}

module.exports = { speechSegments };
