'use strict';

const insights = require('../../services/conversations/conversation_insight_service');

async function handle(job) {
  try {
    return await insights.execute(job.user_id, job.resource_id);
  } catch (error) {
    // A preview is disposable. Retrying a model response that did not match the
    // contract — or that ran out of completion budget — would resend identical
    // input for an identical result, so let the job fail and let the next
    // scheduler tick queue a fresh preview once the conversation has grown.
    // Transport failures stay retryable.
    if (['AI_SCHEMA_INVALID', 'AI_OUTPUT_TRUNCATED'].includes(error.code)) error.retryable = false;
    throw error;
  }
}

module.exports = { handle };
