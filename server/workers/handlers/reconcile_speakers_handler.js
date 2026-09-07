'use strict';

const speakers = require('../../services/speakers/speaker_service');
const settings = require('../../services/settings/settings_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('speaker-resolution');

// Folds duplicate voice profiles back together for one user.
//
// This used to run inline after every transcribed chunk, where it compared every
// enrolled voice against every other one inside a transaction — on the same path
// that has audio waiting to be deleted and a receipt waiting to be issued. It is
// derived cleanup and belongs behind the queue, which also collapses a whole
// recording's requests into a single pass.
async function handle(job) {
  if (!settings.get(job.user_id).recurringSpeakerMatching) return { skipped: 'disabled' };
  const result = speakers.reevaluate(job.user_id);
  if (result.mergedCount) {
    logger.info('Reconciled recurring speaker profiles', {
      userId: job.user_id,
      merged: result.mergedCount,
      remaining: result.remainingCount,
      // Relabeling is silent by design, so the merges themselves are the only
      // record of why two people became one.
      merges: result.merges.map((merge) => ({ ...merge, similarity: Number(merge.similarity.toFixed(3)) })),
    });
  }
  return result;
}

module.exports = { handle };
