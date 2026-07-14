'use strict';

const { getDatabase } = require('../../db/database');
const jobs = require('./job_service');
const consolidation = require('../memories/consolidation_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('scheduler');
let timer;

function tick() {
  const db = getDatabase();
  for (const user of db.prepare('SELECT id FROM users WHERE disabled_at IS NULL').all()) {
    try {
      const boundaryNeeded = db.prepare(`SELECT 1 WHERE EXISTS (
        SELECT 1 FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL
      ) OR EXISTS (
        SELECT 1 FROM conversations WHERE user_id=? AND state='open'
      )`).get(user.id, user.id);
      if (boundaryNeeded) jobs.enqueue({ userId: user.id, resourceType: 'user', resourceId: user.id, type: 'detect_boundaries', priority: 5 });
      consolidation.request(user.id);
    } catch (error) { logger.warn('User scheduling failed', { userId: user.id, error: error.message }); }
  }
  const maintenanceBucket = new Date().toISOString().slice(0, 13);
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: maintenanceBucket, type: 'maintenance', priority: -10 });
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: `events-${maintenanceBucket}`, type: 'prune_events', priority: -20 });
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: `audio-${maintenanceBucket}`, type: 'sweep_temp_audio', priority: 100 });
}

function start(intervalMs = 60_000) {
  if (timer) return;
  tick();
  timer = setInterval(tick, intervalMs);
  timer.unref?.();
}
function stop() { if (timer) clearInterval(timer); timer = undefined; }
module.exports = { start, stop, tick };
