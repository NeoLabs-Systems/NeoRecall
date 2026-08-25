'use strict';

const service = require('../../services/memories/memory_service');

async function handle(job) {
  return service.rewriteMergedProse(job.user_id, job.payload);
}

module.exports = { handle };
