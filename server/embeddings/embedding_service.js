'use strict';

const { getConfig } = require('../config');
const { ensureRuntimeDirs } = require('../../runtime/paths');

let extractorPromise;
async function extractor() {
  if (!extractorPromise) {
    extractorPromise = import('@huggingface/transformers').then(({ pipeline, env }) => {
      env.allowRemoteModels = false;
      env.allowLocalModels = true;
      env.localModelPath = process.env.NEORECALL_TRANSFORMERS_LOCAL_PATH || ensureRuntimeDirs().models;
      if (process.env.NEORECALL_TRANSFORMERS_CACHE) env.cacheDir = process.env.NEORECALL_TRANSFORMERS_CACHE;
      return pipeline('feature-extraction', getConfig().embeddingModel, { dtype: 'q8' });
    });
  }
  return extractorPromise;
}

async function embed(text, prefix = 'passage') {
  const model = await extractor();
  const output = await model(`${prefix}: ${String(text).slice(0, 16_000)}`, {
    pooling: 'mean', normalize: true, truncation: true, max_length: 512,
  });
  const values = output.tolist()[0];
  if (values.length !== getConfig().embeddingDimensions || values.length !== 384) {
    throw new Error(`Embedding model returned ${values.length} dimensions; NeoRecall v1 requires 384.`);
  }
  return new Float32Array(values);
}

function resetForTests() { extractorPromise = undefined; }
module.exports = { embed, resetForTests };
