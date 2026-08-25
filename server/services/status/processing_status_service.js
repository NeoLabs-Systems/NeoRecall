'use strict';

const { getDatabase } = require('../../db/database');
const aiProviders = require('../../ai/provider_registry');
const transcriptionProviders = require('../../transcription/provider_registry');
const consolidation = require('../memories/consolidation_service');

/// Answers the one question a recorder has to be able to answer: "I recorded all
/// day — where did it go?"
///
/// Everything needed to answer it already existed, scattered across chunk states,
/// job rows, consolidation eligibility and provider configuration. What did not
/// exist was anywhere the person who did the recording could see it, so a
/// pipeline stalled at any stage looked exactly like one with nothing to do: an
/// empty timeline. A whole day of speech could be safely stored, correctly
/// transcribed, and waiting on a language model that was rejecting every
/// request, and the app would say nothing at all.
///
/// Written for that person rather than for an operator. Each issue says what is
/// happening to their recordings, why, and what changes it — never an error code
/// or a table name. Severities mean: `blocked`, nothing progresses until someone
/// acts; `attention`, worth a look while the rest keeps moving; `working`,
/// progress with nothing to do.

/// How long queued work may sit before the queue looks stuck rather than busy.
/// Transcribing a backlog is legitimately slow, so this is generous: it is meant
/// to catch a worker that is not running at all.
const STALLED_QUEUE_MS = 30 * 60_000;
const WORKER_SILENT_MS = 5 * 60_000;

function counts(userId) {
  const db = getDatabase();
  const byState = Object.fromEntries(db.prepare('SELECT state,COUNT(*) count FROM audio_chunks WHERE user_id=? GROUP BY state')
    .all(userId).map((row) => [row.state, row.count]));
  return {
    // Audio the recording device is still holding, because no terminal receipt
    // has yet proved its transcript durable. This is the reliability invariant
    // working, not a fault — the number only says how much is in flight.
    inFlight: (byState.uploaded || 0) + (byState.processing || 0) + (byState.persisted_cleanup_pending || 0),
    failing: byState.retryable_failed || 0,
    needsReupload: byState.reupload_required || 0,
    transcribed: (byState.transcribed || 0) + (byState.silent || 0),
    unassignedSegments: db.prepare('SELECT COUNT(*) count FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL').get(userId).count,
    openConversations: db.prepare("SELECT COUNT(*) count FROM conversations WHERE user_id=? AND state='open'").get(userId).count,
    quarantined: db.prepare('SELECT COUNT(*) count FROM conversations WHERE user_id=? AND quarantined_at IS NOT NULL').get(userId).count,
    memories: db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count,
    failedJobs: db.prepare("SELECT type,COUNT(*) count,MAX(last_error_message) message,MAX(last_error_code) code FROM jobs WHERE user_id=? AND status='failed' GROUP BY type").all(userId),
    oldestQueuedAt: db.prepare("SELECT MIN(created_at) value FROM jobs WHERE user_id=? AND status='queued'").get(userId).value,
  };
}

function workerAlive() {
  const row = getDatabase().prepare('SELECT MAX(heartbeat_at) value FROM worker_heartbeats').get();
  return Boolean(row?.value) && Date.now() - Date.parse(row.value) < WORKER_SILENT_MS;
}

function plural(count, singular, many) {
  return `${count} ${count === 1 ? singular : many || `${singular}s`}`;
}

/// Why memories are not appearing, in the user's terms.
///
/// Most eligibility reasons are the system working — waiting for an interval, or
/// for enough material — and produce no issue at all. Only what a person can act
/// on, or would otherwise silently wonder about, is surfaced.
function memoryIssues(eligibility, data) {
  const issues = [];
  if (eligibility.reason === 'ai_not_configured') {
    issues.push({
      severity: 'blocked',
      code: 'LANGUAGE_MODEL_NOT_CONFIGURED',
      title: 'Your recordings are saved, but nothing is being written up',
      detail: 'Transcripts are being kept safely. Turning them into memories needs a language model, and none is set up yet.',
      action: 'Choose a language model in the server’s admin settings.',
    });
  }
  if (eligibility.reason === 'recent_failure') {
    issues.push({
      severity: 'attention',
      code: 'MEMORY_WRITING_FAILING',
      title: 'Writing up your recordings is not succeeding',
      detail: eligibility.errorMessage
        ? `The last ${plural(eligibility.consecutiveFailures, 'attempt')} did not complete. The service reported: ${String(eligibility.errorMessage).slice(0, 200)}`
        : `The last ${plural(eligibility.consecutiveFailures, 'attempt')} did not complete.`,
      action: 'Nothing is lost — the transcripts stay and this retries on its own. If it keeps failing, check the language-model settings.',
      retryAt: eligibility.retryAt,
    });
  }
  if (data.quarantined) {
    issues.push({
      severity: 'attention',
      code: 'CONVERSATIONS_SET_ASIDE',
      title: `${plural(data.quarantined, 'conversation')} could not be written up`,
      detail: 'They are still recorded and searchable. Repeated attempts to summarise them did not succeed, so they were set aside to let everything else through.',
      action: 'They can be retried once the language-model settings change.',
    });
  }
  return issues;
}

function issuesFor(data, eligibility, providers, alive) {
  const issues = [];

  if (!providers.transcription) {
    issues.push({
      severity: 'blocked',
      code: 'TRANSCRIPTION_NOT_CONFIGURED',
      title: 'Recordings are being kept but not turned into text',
      detail: 'Your audio is safe and nothing has been deleted. Transcribing it needs a transcription service, and none is set up yet.',
      action: 'Choose a transcription service in the server’s admin settings.',
    });
  } else if (data.failing) {
    const failure = data.failedJobs.find((row) => row.type === 'transcribe_chunk');
    issues.push({
      severity: 'attention',
      code: 'TRANSCRIPTION_FAILING',
      title: `${plural(data.failing, 'recording')} could not be transcribed`,
      detail: failure?.message
        ? `The transcription service reported: ${String(failure.message).slice(0, 200)}`
        : 'The transcription service did not accept them.',
      action: 'Your device still holds this audio, so nothing is lost. It clears once the transcription settings are corrected.',
    });
  }

  if (data.needsReupload) {
    issues.push({
      severity: 'attention',
      code: 'AUDIO_NEEDS_RESENDING',
      title: `${plural(data.needsReupload, 'recording')} needs sending again`,
      detail: 'The server’s copy could not be processed and was cleared. Your device still has the original.',
      action: 'Keep the app open and connected; it sends them again on its own.',
    });
  }

  if (!alive) {
    issues.push({
      severity: 'blocked',
      code: 'PROCESSING_STOPPED',
      title: 'Processing is not running',
      detail: 'Recordings are still being received and kept, but nothing is being worked on. Your audio is safe in the meantime.',
      action: 'The NeoRecall server needs restarting.',
    });
  } else if (data.oldestQueuedAt && Date.now() - Date.parse(data.oldestQueuedAt) > STALLED_QUEUE_MS) {
    issues.push({
      severity: 'attention',
      code: 'PROCESSING_BEHIND',
      title: 'Processing is running behind',
      detail: 'Work has been waiting longer than expected. A large backlog or a slow transcription service will do this.',
      action: 'Nothing is lost and it will catch up. If it does not, check the transcription service.',
    });
  }

  issues.push(...memoryIssues(eligibility, data));
  return issues;
}

/// One sentence for someone who only wants to know whether to worry.
function summarize(data, issues) {
  const blocked = issues.find((issue) => issue.severity === 'blocked');
  if (blocked) return blocked.title;
  if (issues.length) return issues[0].title;
  if (data.inFlight) return `${plural(data.inFlight, 'recording')} still being processed.`;
  if (!data.transcribed) return 'Nothing recorded yet.';
  return 'Everything you have recorded has been processed.';
}

/// Awaited, because the transcription provider reports readiness asynchronously
/// and a promise is truthy. Reading it synchronously made an unconfigured
/// service look configured, which would have hidden the very problem this exists
/// to report.
async function transcriptionReady() {
  try { return Boolean(await transcriptionProviders.getProvider().ready()); } catch { return false; }
}

async function forUser(userId) {
  const data = counts(userId);
  let eligibility = { eligible: false, reason: 'unknown' };
  try { eligibility = consolidation.eligibility(userId); } catch { /* left as unknown; the issues below still report */ }
  const providers = {
    transcription: await transcriptionReady(),
    languageModel: aiProviders.ready(),
  };
  const alive = workerAlive();
  const issues = issuesFor(data, eligibility, providers, alive);
  return {
    summary: summarize(data, issues),
    healthy: issues.length === 0,
    issues,
    audio: {
      processing: data.inFlight,
      transcribed: data.transcribed,
      needsResending: data.needsReupload,
      failing: data.failing,
      // Every piece not yet proved durable is still on the device that recorded
      // it. Saying so plainly is what stops "where did it go" becoming "did I
      // lose it".
      stillOnYourDevice: data.inFlight + data.needsReupload + data.failing,
    },
    memories: {
      total: data.memories,
      setAside: data.quarantined,
      waitingOn: eligibility.eligible ? null : eligibility.reason,
      retryAt: eligibility.retryAt || null,
    },
    conversations: { open: data.openConversations, awaitingGrouping: data.unassignedSegments },
    providers,
    processingRunning: alive,
  };
}

module.exports = { forUser, issuesFor, summarize, counts, transcriptionReady, STALLED_QUEUE_MS, WORKER_SILENT_MS };
