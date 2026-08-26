'use strict';

const { getDatabase } = require('../../db/database');
const jobs = require('./job_service');
const consolidation = require('../memories/consolidation_service');
const conversationInsights = require('../conversations/conversation_insight_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('scheduler');
let timer;

/// The last reason each user's memory generation was held back.
///
/// The scheduler runs every minute, so logging why it skipped each time would
/// bury everything else — that is exactly how an identical readiness line twelve
/// times a minute made real events unfindable. A stall is a change of state, not
/// an ongoing condition, so it is written once when it starts and once when it
/// clears. Two lines answer "why did nothing happen for six hours".
const lastSkipReason = new Map();

function reportSkip(userId, eligibility) {
  const reason = eligibility.eligible ? null : eligibility.reason;
  if (lastSkipReason.get(userId) === reason) return;
  const previous = lastSkipReason.get(userId);
  lastSkipReason.set(userId, reason);
  if (!reason) {
    if (previous) logger.info('Memory generation is running again', { userId, wasWaitingOn: previous });
    return;
  }
  // Waiting for an interval or for enough speech is the system working, so it is
  // detail rather than news. Anything else means someone may need to act.
  const routine = ['interval', 'insufficient_material', 'insufficient_audio', 'already_running'];
  const write = routine.includes(reason) ? logger.debug : logger.info;
  write('Memory generation is waiting', {
    userId,
    waitingOn: reason,
    ...(eligibility.retryAt ? { retryAt: eligibility.retryAt } : {}),
    ...(eligibility.consecutiveFailures ? { consecutiveFailures: eligibility.consecutiveFailures } : {}),
    ...(eligibility.errorCode ? { lastErrorCode: eligibility.errorCode } : {}),
    ...(eligibility.errorMessage ? { lastError: String(eligibility.errorMessage).slice(0, 300) } : {}),
  });
}

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
      // Previews first: a conversation that is still recording has no other way
      // to become visible, while finished material is already durable. Each gets
      // its own guard so a failure in one never silences the other — previews
      // are convenience, memories are the product.
      try { conversationInsights.request(user.id); } catch (error) { logger.warn('Preview scheduling failed', { userId: user.id, error: error.message }); }
      const requested = consolidation.request(user.id);
      reportSkip(user.id, requested);
    } catch (error) { logger.warn('User scheduling failed', { userId: user.id, error: error.message }); }
  }
  const maintenanceBucket = new Date().toISOString().slice(0, 13);
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: maintenanceBucket, type: 'maintenance', priority: -10 });
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: `events-${maintenanceBucket}`, type: 'prune_events', priority: -20 });
  jobs.enqueue({ resourceType: 'maintenance_bucket', resourceId: `audio-${maintenanceBucket}`, type: 'sweep_temp_audio', priority: 100 });
}

function start(intervalMs = require('../../config').getConfig().schedulerIntervalMs) {
  if (timer) return;
  tick();
  timer = setInterval(tick, intervalMs);
  timer.unref?.();
}
function stop() { if (timer) clearInterval(timer); timer = undefined; }
module.exports = { start, stop, tick };
