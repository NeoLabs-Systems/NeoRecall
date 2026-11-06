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

// Search vectors come from the connected NeoRouter when its embeddings switch is
// on, otherwise from the model that runs here. Both give unit-length vectors of
// the one size the index stores, so a query never has to know which made them.
// `space` names the router's pinned model; it is null for the local one.
// The router's pinned model for each vector it made, so the index can label
// what a vector is comparable with without changing what `embed` returns.
const spaces = new WeakMap();
const spaceOf = (vector) => spaces.get(vector) ?? null;

async function embedDetailed(text, prefix = 'passage') {
  const connection = require('../ai/neorouter/connection').get();
  if (connection?.embeddings) {
    const { embed: routerEmbed } = require('../ai/neorouter/client');
    const result = await routerEmbed(connection, String(text).slice(0, 16_000), { inputType: prefix, dimensions: getConfig().embeddingDimensions });
    spaces.set(result.vector, result.space);
    return { vector: result.vector, space: result.space };
  }
  const model = await extractor();
  const output = await model(`${prefix}: ${String(text).slice(0, 16_000)}`, {
    pooling: 'mean', normalize: true, truncation: true, max_length: 512,
  });
  const values = output.tolist()[0];
  if (values.length !== getConfig().embeddingDimensions || values.length !== 384) {
    throw new Error(`Embedding model returned ${values.length} dimensions; NeoRecall v1 requires 384.`);
  }
  return { vector: new Float32Array(values), space: null };
}

async function embed(text, prefix = 'passage') {
  return (await embedDetailed(text, prefix)).vector;
}

function resetForTests() { extractorPromise = undefined; }
module.exports = { embed, embedDetailed, spaceOf, resetForTests };
