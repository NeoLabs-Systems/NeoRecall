'use strict';

const index = require('../../embeddings/search_index_service');
async function handle(job) { await index.embedDocuments(job.payload.documentIds || [Number(job.resource_id)]); return { embedded: true }; }
module.exports = { handle };
