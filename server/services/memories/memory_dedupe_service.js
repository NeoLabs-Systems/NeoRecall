'use strict';

const { getDatabase } = require('../../db/database');
const processingSettings = require('../settings/processing_settings_service');
const ai = require('../../ai/ai_engine');
const aiProviders = require('../../ai/provider_registry');
const memoryService = require('./memory_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('memories');

// The safety net under memory generation: cards that describe one occasion but
// were written separately, folded back into one.
//
// Consolidating a whole occasion at once is the actual fix and handles the
// ordinary case. It cannot handle every case, because it can only join what it
// can see: a device that reconnects starts a new recording stream, an occasion
// longer than the maximum wait is written up before it ends, and a fragment
// whose transcription finished late arrives after its neighbours were already
// written. Each of those leaves two cards for one sitting.
//
// The shape is deliberate and matches how continuation already works: a cheap
// numeric score decides which pairs are worth a question, and the model decides
// the answer. Nothing is merged on a similarity number.

function cosine(left, right) {
  if (!left || !right || left.length !== right.length) return 0;
  let dot = 0; let a = 0; let b = 0;
  for (let index = 0; index < left.length; index += 1) { dot += left[index] * right[index]; a += left[index] ** 2; b += right[index] ** 2; }
  return a && b ? dot / Math.sqrt(a * b) : 0;
}

// SQLite hands back blobs as views into a shared buffer, and that view is not
// guaranteed to start on a four-byte boundary. Reading one directly as a
// Float32Array throws — so an unaligned row is copied first, exactly as
// voiceprint storage does. Getting this wrong crashes the maintenance job on
// one row rather than returning a wrong answer, which is why it is worth the
// two lines.
function vectorOf(row) {
  const buffer = row.embedding.byteOffset % Float32Array.BYTES_PER_ELEMENT === 0
    ? row.embedding : Buffer.from(row.embedding);
  return new Float32Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / Float32Array.BYTES_PER_ELEMENT);
}

// A memory with the embedding the search index already holds for it.
//
// Every memory is indexed when it is written, so nothing is embedded twice here.
// Matching the two text hashes is what makes the vector trustworthy: a card
// that has not been embedded yet, or one whose text changed and whose new
// embedding has not been computed yet, is simply absent rather than judged on
// wording it no longer has. Indexing is asynchronous, so the next sweep finds it.
const WITH_EMBEDDING = `SELECT m.id,m.public_id,m.type,m.title_en,m.summary_en,m.started_at,m.ended_at,
    e.embedding,e.model_revision
  FROM memories m
  JOIN search_documents d ON d.user_id=m.user_id AND d.kind='memory' AND d.source_id=CAST(m.id AS TEXT)
  JOIN search_embeddings e ON e.document_id=d.id AND e.text_hash=d.text_hash`;

function pending(userId, database) {
  return database.prepare(`${WITH_EMBEDDING}
    WHERE m.user_id=? AND m.dedupe_checked_at IS NULL ORDER BY m.started_at`).all(userId);
}

// Cards close enough in time to be fragments of one sitting.
//
// The window is the guard that keeps two lessons of one course, or two calls
// about one project on the same day, from ever being considered: they read
// alike, so nothing but time separates them. Overlapping ranges count as zero
// distance, which is what a restarted recording of one sitting looks like.
function neighbours(userId, memory, windowMs, database) {
  const from = new Date(Date.parse(memory.started_at) - windowMs).toISOString();
  const to = new Date(Date.parse(memory.ended_at) + windowMs).toISOString();
  return database.prepare(`${WITH_EMBEDDING}
    WHERE m.user_id=? AND m.id<>? AND m.ended_at>=? AND m.started_at<=?
    ORDER BY m.started_at`).all(userId, memory.id, from, to);
}

function detailFor(userId, memoryId, database) {
  const topics = database.prepare('SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic').all(memoryId).map((row) => row.topic);
  const miniMemories = database.prepare('SELECT text_en FROM mini_memories WHERE memory_id=? AND user_id=? ORDER BY importance DESC,id DESC LIMIT 8')
    .all(memoryId, userId);
  return { topics, miniMemories };
}

// Whether the two cards come from one recording. Evidence for the model, not a
// decision: a reconnecting device produces two streams for one sitting, and one
// stream running all day produces many sittings.
function sharesStream(memoryId, otherId, database) {
  return Boolean(database.prepare(`SELECT 1 FROM memory_sources a
    JOIN transcript_segments ta ON ta.id=a.segment_id
    JOIN audio_chunks ca ON ca.id=ta.chunk_id
    JOIN memory_sources b ON b.memory_id=?
    JOIN transcript_segments tb ON tb.id=b.segment_id
    JOIN audio_chunks cb ON cb.id=tb.chunk_id AND cb.session_id=ca.session_id
    WHERE a.memory_id=? LIMIT 1`).get(otherId, memoryId));
}

function minutesApart(left, right) {
  const gap = Math.max(
    Date.parse(right.started_at) - Date.parse(left.ended_at),
    Date.parse(left.started_at) - Date.parse(right.ended_at),
  );
  return Math.max(0, Math.round(gap / 60_000));
}

function markChecked(ids, database) {
  if (!ids.length) return;
  database.prepare(`UPDATE memories SET dedupe_checked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id IN (${ids.map(() => '?').join(',')})`).run(...ids);
}

// One pass over the cards this user has gained since the last pass.
//
// Never throws: it is derived cleanup running inside the maintenance job, and a
// model that is down or an answer that will not parse must not stop retention,
// receipts or summaries from running. Whatever it could not judge stays
// unmarked and is tried again next time.
async function sweep(userId, options = processingSettings.get(), database = getDatabase()) {
  const result = { judged: 0, merged: 0 };
  if (!options.memoryDedupeEnabled || !aiProviders.ready()) return result;

  const checked = [];
  // Two unjudged cards are each other's neighbour, so without this the same
  // pair is put to the model twice in one sweep — the same question, the same
  // answer, paid for twice.
  const asked = new Set();
  const pairKey = (left, right) => (left < right ? `${left}\0${right}` : `${right}\0${left}`);
  for (const memory of pending(userId, database)) {
    if (result.judged >= options.memoryDedupeMaxPairsPerRun) break;
    // A card merged earlier in this same sweep no longer exists.
    if (!database.prepare('SELECT 1 FROM memories WHERE id=?').get(memory.id)) continue;
    const vector = vectorOf(memory);

    const ranked = neighbours(userId, memory, options.memoryDedupeWindowMs, database)
      // Embeddings from different models are not comparable at all.
      .filter((other) => other.model_revision === memory.model_revision)
      .map((other) => ({ other, similarity: cosine(vector, vectorOf(other)) }))
      .filter((item) => item.similarity >= options.memoryDedupeSimilarityThreshold)
      .sort((left, right) => right.similarity - left.similarity)
      .slice(0, options.memoryDedupeNeighbours);

    let absorbed = false;
    for (const { other, similarity } of ranked) {
      if (result.judged >= options.memoryDedupeMaxPairsPerRun) break;
      if (!database.prepare('SELECT 1 FROM memories WHERE id=?').get(other.id)) continue;
      if (asked.has(pairKey(memory.id, other.id))) continue;
      asked.add(pairKey(memory.id, other.id));
      let decision;
      try {
        result.judged += 1;
        const answer = await ai.judgeDuplicateMemories(userId,
          { ...memory, ...detailFor(userId, memory.id, database) },
          { ...other, ...detailFor(userId, other.id, database) },
          { minutesApart: minutesApart(memory, other), sameStream: sharesStream(memory.id, other.id, database) });
        decision = answer.value;
      } catch (error) {
        // Leave both unmarked: the question has not been answered, so it is
        // still worth asking once the cause is gone.
        logger.warn('Could not judge whether two memories describe one occasion', {
          userId, errorCode: error.code || 'MEMORY_DEDUPE_FAILED', error,
        });
        // Keep what this pass did settle. Only the pair it could not ask about
        // stays unmarked, so a provider that comes back does not re-buy every
        // answer given before it went away.
        markChecked(checked, database);
        return result;
      }
      if (!decision.sameOccasion) continue;
      try {
        const merged = memoryService.merge(userId, { ids: [memory.public_id, other.public_id] }, { automatic: true });
        result.merged += 1;
        absorbed = true;
        // The survivor is a different card now. Clearing its mark sends the
        // combined text back through the sweep, which is how a sitting that
        // arrived in three pieces ends as one card rather than two.
        database.prepare('UPDATE memories SET dedupe_checked_at=NULL WHERE public_id=? AND user_id=?')
          .run(merged.memory.id, userId);
        logger.info('Folded two cards describing one occasion into one', {
          userId, memory: merged.memory.id, absorbed: merged.absorbedIds,
          similarity: Number(similarity.toFixed(3)), reason: decision.reasoning.slice(0, 200),
        });
      } catch (error) {
        // A card deleted or merged between the query and the write. Nothing to
        // repair; the survivor is judged again on the next sweep.
        logger.warn('A memory changed before its duplicate could be folded in', {
          userId, errorCode: error.code || 'MEMORY_MERGE_FAILED',
        });
      }
      // The surviving card has changed: whatever it now says has to be judged
      // afresh rather than against the text this pass read.
      break;
    }
    if (!absorbed) checked.push(memory.id);
  }
  markChecked(checked, database);
  return result;
}

module.exports = { sweep, cosine };
