'use strict';

const archive = require('../../services/cloud/archive_service');

async function handle(job) {
  if (job.type === 'cloud_put') return archive.drain(job.user_id);
  if (job.type === 'cloud_user_backup') {
    return archive.backupUserData(job.user_id, { force: job.payload?.triggerKind === 'manual' });
  }
  return { skipped: true };
}

module.exports = { handle };
