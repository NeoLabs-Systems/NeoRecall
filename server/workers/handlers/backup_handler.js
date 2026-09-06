'use strict';

const backups = require('../../services/backup/backup_service');

async function handle(job) {
  return backups.run({ triggerKind: job.payload_json && JSON.parse(job.payload_json).triggerKind === 'manual' ? 'manual' : 'scheduled' });
}

module.exports = { handle };
