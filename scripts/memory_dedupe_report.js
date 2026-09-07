'use strict';

require('../runtime/env').loadEnvironment();

// Which memory cards this installation would consider duplicates, and how alike
// they actually read.
//
// NEORECALL_MEMORY_DEDUPE_SIMILARITY_THRESHOLD decides which pairs are worth a
// model request at all, and it was chosen against a guess: multilingual-e5
// similarities sit high even between unrelated text, so a number that reads
// cautious can be far too permissive, or far too strict, on real recordings.
// This prints the pairs and where their scores fall, so the threshold is set
// against this database rather than against an intuition.
//
// Read-only by construction — it opens the database, runs SELECTs, and prints.
// It never asks the model anything and never merges a card.

const { getDatabase } = require('../server/db/database');
const processingSettings = require('../server/services/settings/processing_settings_service');
const { cosine } = require('../server/services/memories/memory_dedupe_service');

const BUCKETS = Object.freeze([0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9, 0.93, 0.95, 0.98]);

function histogram(scores) {
  const counts = new Array(BUCKETS.length + 1).fill(0);
  for (const score of scores) {
    let index = 0;
    while (index < BUCKETS.length && score >= BUCKETS[index]) index += 1;
    counts[index] += 1;
  }
  return counts;
}

function renderHistogram(scores, threshold) {
  if (!scores.length) return '  no pairs inside the time window\n';
  const counts = histogram(scores);
  const widest = Math.max(...counts, 1);
  const lines = counts.map((count, index) => {
    const low = index === 0 ? '   <' : ' >= ';
    const edge = index === 0 ? BUCKETS[0] : BUCKETS[index - 1];
    const mark = edge >= threshold && index > 0 ? ' <- asked about' : '';
    const bar = '#'.repeat(Math.round((count / widest) * 40));
    return `  ${low}${edge.toFixed(2)} ${String(count).padStart(5)} ${bar}${mark}`;
  });
  return `${lines.join('\n')}\n`;
}

function vectorOf(row) {
  const buffer = row.embedding;
  return new Float32Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / Float32Array.BYTES_PER_ELEMENT);
}

function cards(database, userId) {
  return database.prepare(`SELECT m.id,m.title_en,m.started_at,m.ended_at,e.embedding,e.model_revision
    FROM memories m
    JOIN search_documents d ON d.user_id=m.user_id AND d.kind='memory' AND d.source_id=CAST(m.id AS TEXT)
    JOIN search_embeddings e ON e.document_id=d.id AND e.text_hash=d.text_hash
    WHERE m.user_id=? ORDER BY m.started_at`).all(userId);
}

function minutesApart(left, right) {
  const gap = Math.max(
    Date.parse(right.started_at) - Date.parse(left.ended_at),
    Date.parse(left.started_at) - Date.parse(right.ended_at),
  );
  return Math.max(0, Math.round(gap / 60_000));
}

function reportForUser(database, user, limits) {
  const rows = cards(database, user.id);
  const total = database.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(user.id).count;
  const out = [`\n${user.username}: ${total} cards, ${rows.length} with a current embedding`];
  if (!rows.length) return `${out.join('\n')}\n`;

  const pairs = [];
  for (let i = 0; i < rows.length; i += 1) {
    for (let j = i + 1; j < rows.length; j += 1) {
      if (rows[i].model_revision !== rows[j].model_revision) continue;
      // Ordered by start, so once a card is beyond the window every later one is.
      if (Date.parse(rows[j].started_at) - Date.parse(rows[i].ended_at) > limits.memoryDedupeWindowMs) break;
      pairs.push({ left: rows[i], right: rows[j], similarity: cosine(vectorOf(rows[i]), vectorOf(rows[j])) });
    }
  }
  out.push(renderHistogram(pairs.map((pair) => pair.similarity), limits.memoryDedupeSimilarityThreshold));

  const asked = pairs.filter((pair) => pair.similarity >= limits.memoryDedupeSimilarityThreshold)
    .sort((left, right) => right.similarity - left.similarity);
  out.push(`  ${asked.length} of ${pairs.length} pairs would reach the model:`);
  // The point of the list is to be read: if these are not obviously fragments
  // of one sitting, the threshold is too low, whatever the histogram says.
  for (const pair of asked.slice(0, 25)) {
    out.push(`    ${pair.similarity.toFixed(3)}  ${minutesApart(pair.left, pair.right)} min apart`
      + `\n      ${pair.left.title_en}\n      ${pair.right.title_en}`);
  }
  if (asked.length > 25) out.push(`    … and ${asked.length - 25} more`);
  return `${out.join('\n')}\n`;
}

function main() {
  const database = getDatabase();
  const migrated = database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='memories'").get();
  if (!migrated) {
    process.stdout.write(`No NeoRecall database at ${require('../runtime/paths').paths().home}. Set NEORECALL_HOME to the installation you want to inspect.\n`);
    return;
  }
  const limits = processingSettings.get();
  const users = database.prepare('SELECT id,username FROM users WHERE disabled_at IS NULL ORDER BY username').all();
  if (!users.length) {
    process.stdout.write('No active users in this database.\n');
    return;
  }
  process.stdout.write('Duplicate memory report\n');
  process.stdout.write(`Limits in force: similarity ${limits.memoryDedupeSimilarityThreshold},`
    + ` window ${Math.round(limits.memoryDedupeWindowMs / 60_000)} min,`
    + ` at most ${limits.memoryDedupeMaxPairsPerRun} questions per sweep\n`);
  for (const user of users) process.stdout.write(reportForUser(database, user, limits));
}

if (require.main === module) main();

module.exports = { histogram, BUCKETS };
