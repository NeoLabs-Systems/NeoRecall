'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const processingSettings = require('../../services/settings/processing_settings_service');
const { sha256 } = require('../../utils/crypto');
const tempAudio = require('../../services/ingest/temp_audio_service');
const receiptService = require('../../services/ingest/receipt_service');
const jobs = require('../../services/jobs/job_service');
const settings = require('../../services/settings/settings_service');
const searchIndex = require('../../embeddings/search_index_service');
const deduper = require('../../transcription/token_deduper');
const matching = require('../../transcription/speaker_matching');
const speakerPreviews = require('../../services/speakers/speaker_preview_service');
const { createLogger } = require('../../utils/logger');
const logger = createLogger('transcribe-handler');

function captureSpeakerPreviews(chunk, segmentCount) {
  if (!segmentCount) return;
  try {
    speakerPreviews.captureFromChunk(chunk);
  } catch (error) {
    // A derived convenience sample must never block original-audio cleanup or
    // the terminal receipt. A later chunk for the same voice can retry it.
    logger.warn('Speaker preview extraction failed', {
      chunkId: chunk.id,
      errorCode: error.code || 'SPEAKER_PREVIEW_FAILED',
      error,
    });
  }
}

function absoluteIso(sessionStart, monotonicOffsetMs, relativeMs) {
  return new Date(Date.parse(sessionStart) + monotonicOffsetMs + relativeMs).toISOString();
}

function previousSegments(database, chunk) {
  return database.prepare(`SELECT t.text,t.asr_confidence asrConfidence,
    (julianday(t.started_at)-2440587.5)*86400000 startMs,(julianday(t.ended_at)-2440587.5)*86400000 endMs
    FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
    WHERE c.source_id=? AND c.sequence<? AND c.sequence>=? ORDER BY t.started_at`)
    .all(chunk.source_id, chunk.sequence, Math.max(0, chunk.sequence - 2));
}

function updateContiguous(database, sourceId) {
  const rows = database.prepare('SELECT sequence,state FROM audio_chunks WHERE source_id=? ORDER BY sequence').all(sourceId);
  const gaps = database.prepare(`SELECT start_sequence,end_sequence FROM recording_gaps
    WHERE source_id=? AND start_sequence IS NOT NULL ORDER BY start_sequence`).all(sourceId);
  const covered = (sequence) => gaps.some((gap) => sequence >= gap.start_sequence && sequence <= gap.end_sequence);
  const terminal = new Map(rows.map((row) => [row.sequence, receiptService.terminalStates.has(row.state)]));
  const maximum = Math.max(-1, ...rows.map((row) => row.sequence), ...gaps.map((gap) => gap.end_sequence));
  let contiguous = -1;
  for (let sequence = 0; sequence <= maximum; sequence += 1) {
    if (!terminal.get(sequence) && !covered(sequence)) break;
    contiguous = sequence;
  }
  database.prepare('UPDATE recording_sources SET contiguous_terminal_sequence=? WHERE id=?').run(contiguous, sourceId);
}

function persistSegments(chunk, inferred) {
  const db = getDatabase();
  const session = db.prepare('SELECT * FROM recording_sessions WHERE id=? AND user_id=?').get(chunk.session_id, chunk.user_id);
  if (!session) throw Object.assign(new Error('Recording session no longer exists.'), { code: 'SESSION_MISSING' });
  const normalized = inferred.map((segment) => ({ ...segment,
    startMs: Date.parse(absoluteIso(session.corrected_started_at, chunk.monotonic_offset_ms, segment.startMs)),
    endMs: Date.parse(absoluteIso(session.corrected_started_at, chunk.monotonic_offset_ms, segment.endMs)),
  }));
  const processingConfig = processingSettings.get();
  const clean = deduper.dedupe(normalized, previousSegments(db, chunk), {
    similarityThreshold: processingConfig.dedupeTokenSimilarity, timeToleranceMs: processingConfig.dedupeTimeToleranceMs,
  });
  const canonical = clean.map((segment) => ({ start: segment.startMs, end: segment.endMs, text: segment.text, language: segment.language || null }));
  const checksum = sha256(JSON.stringify(canonical));
  db.transaction(() => {
    db.prepare("UPDATE audio_chunks SET state='processing',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(chunk.id);
    const speakerCache = new Map();
    const recurringMatching = settings.get(chunk.user_id).recurringSpeakerMatching;
    const insertSegment = db.prepare(`INSERT INTO transcript_segments
      (public_id,user_id,chunk_id,speaker_cluster_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language,asr_confidence,speaker_confidence,overlapping_speech)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
    const insertTurn = db.prepare(`INSERT INTO speaker_turns
      (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions,confidence,quality,overlapping_speech)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
    for (const segment of clean) {
      let cluster = null; let voiceprint = null;
      if (segment.speakerEmbedding) {
        const key = `${segment.sourceComponent}:${segment.diarizationSpeaker}`;
        let resolved = speakerCache.get(key);
        if (!resolved) {
          const embedding = segment.speakerEmbedding instanceof Float32Array ? segment.speakerEmbedding : new Float32Array(Object.values(segment.speakerEmbedding));
          cluster = matching.resolveCluster(db, { userId: chunk.user_id, sessionId: chunk.session_id, embedding });
          voiceprint = matching.resolveVoiceprint(db, { userId: chunk.user_id, clusterId: cluster.id, embedding, enabled: recurringMatching });
          resolved = { cluster, voiceprint, embedding };
          speakerCache.set(key, resolved);
        } else ({ cluster, voiceprint } = resolved);
      }
      const publicId = crypto.randomUUID();
      const relativeStart = Math.max(0, Math.round(segment.startMs - Date.parse(session.corrected_started_at) - chunk.monotonic_offset_ms));
      const relativeEnd = Math.max(relativeStart, Math.round(segment.endMs - Date.parse(session.corrected_started_at) - chunk.monotonic_offset_ms));
      const result = insertSegment.run(publicId, chunk.user_id, chunk.id, cluster?.id || null, segment.sourceComponent || 'combined',
        new Date(segment.startMs).toISOString(), new Date(segment.endMs).toISOString(), relativeStart, relativeEnd, segment.text,
        segment.language || null, segment.asrConfidence ?? null, segment.speakerConfidence ?? null, Number(Boolean(segment.overlappingSpeech)));
      if (cluster && segment.speakerEmbedding) {
        const embedding = segment.speakerEmbedding instanceof Float32Array ? segment.speakerEmbedding : new Float32Array(Object.values(segment.speakerEmbedding));
        insertTurn.run(crypto.randomUUID(), chunk.user_id, chunk.id, cluster.id, voiceprint?.id || null, relativeStart, relativeEnd,
          Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength), matching.modelName, embedding.length,
          segment.speakerConfidence ?? null, segment.overlappingSpeech ? 0.5 : 1, Number(Boolean(segment.overlappingSpeech)));
      }
      searchIndex.upsertDocument({ userId: chunk.user_id, kind: 'segment', sourceId: Number(result.lastInsertRowid), body: segment.text,
        occurredAt: new Date(segment.startMs).toISOString(), importance: 0 }, db);
    }
    db.prepare(`UPDATE audio_chunks SET state='persisted_cleanup_pending',transcript_sha256=?,transcript_segment_count=?,
      persisted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),error_code=NULL,error_message=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
      .run(checksum, clean.length, chunk.id);
    db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
      VALUES (?,'chunk.persisted','audio_chunk',?,?,?)`).run(chunk.user_id, chunk.id,
      JSON.stringify({ chunkId: chunk.id, state: 'persisted_cleanup_pending', segmentCount: clean.length }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
  })();
  return clean.length;
}

function finishCleanup(chunk, segmentCount) {
  const db = getDatabase();
  try { tempAudio.unlinkStrict(chunk.temporary_path); } catch (error) {
    jobs.enqueue({ userId: chunk.user_id, resourceType: 'audio_chunk', resourceId: chunk.id, type: 'cleanup_chunk_audio', priority: 110 });
    return { state: 'persisted_cleanup_pending', segmentCount };
  }
  const receipt = db.transaction(() => {
    db.prepare('UPDATE audio_chunks SET temporary_path=NULL WHERE id=?').run(chunk.id);
    const receipt = receiptService.completeTerminal(db, chunk.id, segmentCount ? 'transcribed' : 'silent');
    updateContiguous(db, chunk.source_id);
    db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
      VALUES (?,'chunk.terminal','audio_chunk',?,?,?)`).run(chunk.user_id, chunk.id, JSON.stringify(receipt), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
    if (segmentCount) jobs.enqueue({ userId: chunk.user_id, resourceType: 'user', resourceId: chunk.user_id, type: 'detect_boundaries', priority: 10 }, db);
    return receipt;
  })();
  require('../../services/ingest/import_service').reconcileProcessing();
  return receipt;
}

async function handle(job, inference) {
  const db = getDatabase();
  const chunk = db.prepare('SELECT * FROM audio_chunks WHERE id=? AND user_id=?').get(job.resource_id, job.user_id);
  if (!chunk) return { deleted: true };
  if (receiptService.terminalStates.has(chunk.state)) return receiptService.receipt(chunk);
  if (chunk.state === 'persisted_cleanup_pending') {
    captureSpeakerPreviews(chunk, chunk.transcript_segment_count);
    return finishCleanup(chunk, chunk.transcript_segment_count || 0);
  }
  if (!chunk.temporary_path) throw Object.assign(new Error('Server audio is missing and must be uploaded again.'), { code: 'AUDIO_REUPLOAD_REQUIRED', retryable: false });
  db.prepare("UPDATE audio_chunks SET state='processing',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(chunk.id);
  const inferenceStartedAt = process.hrtime.bigint();
  const segments = await inference({ filename: chunk.temporary_path, channelLayout: chunk.channel_layout, provider: getConfig().transcriptionProvider });
  const inferenceSeconds = Number(process.hrtime.bigint() - inferenceStartedAt) / 1e9;
  db.prepare(`INSERT INTO processing_metrics (job_id,user_id,metric,value,unit)
    VALUES (?,?,'transcription_pipeline_rtf',?,'ratio')`).run(job.id, chunk.user_id, inferenceSeconds / (chunk.duration_ms / 1000));
  const count = persistSegments(chunk, segments);
  captureSpeakerPreviews(chunk, count);
  return finishCleanup(chunk, count);
}

module.exports = { handle, persistSegments, finishCleanup, updateContiguous };
