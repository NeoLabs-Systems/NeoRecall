'use strict';

require('../runtime/env').loadEnvironment();
const models = require('../lib/model_downloader');
const path = require('node:path');
const { ensureRuntimeDirs } = require('../runtime/paths');

async function main() {
  const failures = await models.verifyAll();
  if (failures.length) throw new Error(`Model verification failed: ${JSON.stringify(failures)}`);
  const database = require('../server/db/database').getDatabase();
  const vectorVersion = database.prepare('SELECT vec_version() version').get().version;
  process.env.NEORECALL_TRANSFORMERS_CACHE = path.join(ensureRuntimeDirs().models, 'embeddings');
  const embedding = await require('../server/embeddings/embedding_service').embed('NeoRecall verification', 'passage');
  if (embedding.length !== 384) throw new Error(`Embedding model returned ${embedding.length} dimensions instead of 384.`);
  const provider = require('../server/transcription/provider_registry').getProvider();
  if (!(await provider.ready())) throw new Error('The configured transcription provider is not ready.');
  if (provider.getRecognizer) provider.getRecognizer();
  process.stdout.write(`Verified ${models.manifest.models.length} model groups, 384-dimensional embeddings, and sqlite-vec ${vectorVersion}.\n`);
}

main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
