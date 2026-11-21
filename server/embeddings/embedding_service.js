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
    const result = await routerEmbed(connection, String(text).slice(0, 16_000), prefix);
    spaces.set(result.vector, result.space);
    return { vector: result.vector, space: result.space };
  }
  return { vector: await embedLocal(text, prefix), space: null };
}

// A router key stays pinned to the model it first used. If that model never
// answers at the index size, no vector of ours came from it, so the pin can be
// reset once and the router lets the key pick a model that does.
async function routerEmbed(connection, text, prefix) {
  const client = require('../ai/neorouter/client');
  const options = { inputType: prefix, dimensions: getConfig().embeddingDimensions };
  try {
    return await client.embed(connection, text, options);
  } catch (error) {
    const unused = (space) => require('../db/database').getDatabase()
      .prepare('SELECT 1 FROM search_embeddings WHERE model_revision=? LIMIT 1').get(`neorouter:${space}@${options.dimensions}`) === undefined;
    if (!(await client.resetUnusedPin(connection, error, unused))) throw error;
    return client.embed(connection, text, options);
  }
}

// The model that runs here, whatever the router settings say. Install and
// update check this one: the router is a service that can be down for a while
// without the app being broken.
async function embedLocal(text, prefix = 'passage') {
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

async function embed(text, prefix = 'passage') {
  return (await embedDetailed(text, prefix)).vector;
}

function resetForTests() { extractorPromise = undefined; }
module.exports = { embed, embedDetailed, embedLocal, spaceOf, resetForTests };
