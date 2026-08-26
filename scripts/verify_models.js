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
  // Loading the audio models is part of verifying them: a checksum can pass
  // while a session still fails to build.
  const localAnalysis = require('../server/transcription/local_analysis');
  let speakerIdentity = 'unavailable on this platform';
  if (localAnalysis.available()) {
    require('../server/transcription/vad').speechSegments(new Float32Array(16000));
    require('../server/transcription/diarization').diarize(new Float32Array(16000));
    speakerIdentity = 'ready';
  }
  process.stdout.write(`Verified ${models.manifest.models.length} model groups, 384-dimensional embeddings, sqlite-vec ${vectorVersion}, speaker identity ${speakerIdentity}.\n`);
  // Reported, never fatal: the provider may be configured via the admin
  // dashboard rather than the environment this command sees.
  const provider = require('../server/transcription/provider_registry').getProvider();
  if (!(await provider.ready())) {
    process.stdout.write('No transcription provider is configured yet; set one in .env or the admin dashboard.\n');
  }
}

main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
