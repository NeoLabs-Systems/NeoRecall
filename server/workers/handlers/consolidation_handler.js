'use strict';

const service = require('../../services/memories/consolidation_service');
async function handle(job) {
  return service.execute(job.payload.runId || job.resource_id, job.payload.conversationIds || null);
}
module.exports = { handle };
