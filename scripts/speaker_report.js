'use strict';

require('../runtime/env').loadEnvironment();

// What speaker identity actually looks like on this installation.
//
// Every threshold in the speaker pipeline was chosen against a two-voice
// measurement, and a threshold chosen that way is a guess about everybody
// else's recordings. This reads the database and says what is really there:
// how often one person is listed twice, how much speech carries no durable
// identity at all, and where the similarity scores actually fall. Run it
// before changing a threshold and again afterwards, so "one person no longer
// appears several times" is a number rather than an impression.
//
// Read-only by construction — it opens the database, runs SELECTs, and prints.

const { getDatabase } = require('../server/db/database');
const vectors = require('../server/transcription/speaker_embeddings');
const voiceprintStorage = require('../server/transcription/voiceprint_storage');
const processingSettings = require('../server/services/settings/processing_settings_service');

// Similarity buckets wide enough to read at a glance and narrow enough to show
// where a threshold would land. Cosine below zero never happens between two
// real voices, so everything under 0.3 collapses into one bucket.
const BUCKETS = Object.freeze([0.3, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8, 0.9]);

function histogram(scores) {
  const counts = new Array(BUCKETS.length + 1).fill(0);
  for (const score of scores) {
    let index = 0;
    while (index < BUCKETS.length && score >= BUCKETS[index]) index += 1;
    counts[index] += 1;
  }
  return counts;
}

function renderHistogram(label, scores, marks) {
  if (!scores.length) return `${label}: no pairs to compare\n`;
  const counts = histogram(scores);
  const widest = Math.max(...counts, 1);
  const lines = [`${label} (${scores.length} pairs)`];
  for (let index = counts.length - 1; index >= 0; index -= 1) {
    const lower = index === 0 ? -1 : BUCKETS[index - 1];
    const upper = index === BUCKETS.length ? 1 : BUCKETS[index];
    const bar = '#'.repeat(Math.round((counts[index] / widest) * 40));
    const marked = Object.entries(marks)
      .filter(([, value]) => value > lower && value <= upper)
      .map(([name]) => name);
    const note = marked.length ? `  <- ${marked.join(', ')}` : '';
    lines.push(`  ${lower.toFixed(2).padStart(5)}..${upper.toFixed(2)} ${String(counts[index]).padStart(6)} ${bar}${note}`);
  }
  return `${lines.join('\n')}\n`;
}

function users(database) {
  return database.prepare('SELECT id,username FROM users WHERE disabled_at IS NULL ORDER BY created_at').all();
}

// Every pair of enrolled voices, scored against each other. A pair sitting above
// the match threshold is a duplicate matching should already have folded away;
// a crowd of pairs just below it is the population the repair bar has to reach.
function profilePairs(database, userId) {
  const rows = database.prepare(`SELECT id,display_name,external_key,centroid_embedding,embedding_model,embedding_dimensions
    FROM voiceprints WHERE user_id=? AND centroid_embedding IS NOT NULL AND sample_count>0`).all(userId);
  const centroids = rows.map((row) => ({ row, vector: voiceprintStorage.readCentroid(row.centroid_embedding) }));
  const scores = [];
  const suspicious = [];
  for (let left = 0; left < centroids.length; left += 1) {
    for (let right = left + 1; right < centroids.length; right += 1) {
      if (centroids[left].row.embedding_dimensions !== centroids[right].row.embedding_dimensions) continue;
      const score = vectors.cosine(centroids[left].vector, centroids[right].vector);
      scores.push(score);
      suspicious.push({ score, left: centroids[left].row, right: centroids[right].row });
    }
  }
  suspicious.sort((first, second) => second.score - first.score);
  return {
    count: rows.length,
    named: rows.filter((row) => row.display_name).length,
    declared: rows.filter((row) => row.external_key).length,
    scores,
    closest: suspicious.slice(0, 5),
  };
}

// The within-conversation symptom, counted. `labels` is what the user actually
// sees on a transcript; `clusters` is how many voices the pipeline believes it
// heard. A conversation whose label count exceeds its plausible speaker count is
// one person wearing several names.
function conversationSplits(database, userId) {
  return database.prepare(`SELECT c.id,c.started_at,
      COUNT(DISTINCT cs.cluster_id) clusters,
      COUNT(DISTINCT cs.local_label) labels,
      COUNT(DISTINCT cs.voiceprint_id) voiceprints
    FROM conversations c JOIN conversation_speakers cs ON cs.conversation_id=c.id
    WHERE c.user_id=? GROUP BY c.id HAVING labels>1 ORDER BY labels DESC,c.started_at DESC`).all(userId);
}

// How much of a conversation's speech resolves to a person at all. Turns with no
// voiceprint are why a cluster falls back to its own local label: the identity
// key in rebuildConversationSpeakers has nothing durable to group on.
function unresolvedTurns(database, userId) {
  return database.prepare(`SELECT COUNT(*) total,
      SUM(CASE WHEN voiceprint_id IS NULL THEN 1 ELSE 0 END) unresolved,
      SUM(CASE WHEN voiceprint_id IS NULL THEN end_ms-start_ms ELSE 0 END) unresolved_ms,
      SUM(end_ms-start_ms) total_ms
    FROM speaker_turns WHERE user_id=?`).get(userId);
}

// Distinct clusters inside one conversation, scored against each other. This is
// the population the deferred per-conversation pass would cluster, so it is the
// distribution its merge threshold has to be chosen against — and it is not the
// same distribution as the cross-recording one above.
function withinConversationPairs(database, userId) {
  const rows = database.prepare(`SELECT DISTINCT t.conversation_id,t.speaker_cluster_id cluster_id,sc.centroid_embedding
    FROM transcript_segments t JOIN speaker_clusters sc ON sc.id=t.speaker_cluster_id
    WHERE t.user_id=? AND t.conversation_id IS NOT NULL AND sc.centroid_embedding IS NOT NULL`).all(userId);
  const byConversation = new Map();
  for (const row of rows) {
    if (!byConversation.has(row.conversation_id)) byConversation.set(row.conversation_id, []);
    byConversation.get(row.conversation_id).push(vectors.fromBuffer(row.centroid_embedding));
  }
  const scores = [];
  for (const centroids of byConversation.values()) {
    for (let left = 0; left < centroids.length; left += 1) {
      for (let right = left + 1; right < centroids.length; right += 1) {
        if (centroids[left].length !== centroids[right].length) continue;
        scores.push(vectors.cosine(centroids[left], centroids[right]));
      }
    }
  }
  return scores;
}

function reportForUser(database, user, limits) {
  const profiles = profilePairs(database, user.id);
  const splits = conversationSplits(database, user.id);
  const turns = unresolvedTurns(database, user.id);
  const withinScores = withinConversationPairs(database, user.id);
  const duplicates = profiles.scores.filter((score) => score >= limits.voiceRepairThreshold).length;
  const conversations = database.prepare('SELECT COUNT(*) count FROM conversations WHERE user_id=?').get(user.id).count;

  const out = [];
  out.push(`\n=== ${user.username} ===`);
  out.push(`Speaker profiles: ${profiles.count} (${profiles.named} named)`);
  // Identity that came from the recording rather than from the sound of the
  // voice. These are exact, so a high share here is the cheapest accuracy an
  // installation can have.
  out.push(`Identified by the recording itself rather than by voice: ${profiles.declared}`);
  out.push(`Profile pairs at or above the repair bar (${limits.voiceRepairThreshold}): ${duplicates}`
    + ' — each is one person listed twice that matching has not folded away');
  const unresolvedShare = turns.total ? ((turns.unresolved / turns.total) * 100).toFixed(1) : '0.0';
  const unresolvedMinutes = ((turns.unresolved_ms || 0) / 60000).toFixed(1);
  out.push(`Speaker turns with no durable identity: ${turns.unresolved || 0}/${turns.total || 0}`
    + ` (${unresolvedShare}%, ${unresolvedMinutes} min) — these fall back to a per-cluster label`);
  out.push(`Conversations: ${conversations}; with more than one speaker label: ${splits.length}`);
  const worst = splits.slice(0, 5);
  if (worst.length) {
    out.push('Most-split conversations (labels / clusters / distinct voiceprints):');
    for (const row of worst) out.push(`  ${row.started_at}  ${row.labels} / ${row.clusters} / ${row.voiceprints}`);
  }
  if (profiles.closest.length) {
    out.push('Closest profile pairs — the merges a repair pass would consider first:');
    for (const pair of profiles.closest) {
      const name = (row) => row.display_name || `(unnamed ${row.id.slice(0, 8)})`;
      out.push(`  ${pair.score.toFixed(3)}  ${name(pair.left)}  ~  ${name(pair.right)}`);
    }
  }
  out.push('');
  out.push(renderHistogram('Cross-recording similarity between enrolled profiles', profiles.scores, {
    'enroll floor': limits.voiceEnrollFloor,
    'repair bar': limits.voiceRepairThreshold,
    'match bar': limits.voiceMatchThreshold,
  }));
  out.push(renderHistogram('Within-conversation similarity between clusters', withinScores, {
    'cluster merge bar': limits.speakerClusterMergeThreshold,
  }));
  return out.join('\n');
}

function main() {
  const database = getDatabase();
  // Pointed at a home that has never run the server, every query below fails on
  // a missing table. Say which database was opened instead, since the usual
  // cause is NEORECALL_HOME pointing somewhere unexpected.
  const migrated = database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='voiceprints'").get();
  if (!migrated) {
    process.stdout.write(`No NeoRecall database at ${require('../runtime/paths').paths().home}. Set NEORECALL_HOME to the installation you want to inspect.\n`);
    return;
  }
  const limits = processingSettings.get();
  const rows = users(database);
  if (!rows.length) {
    process.stdout.write('No active users in this database.\n');
    return;
  }
  process.stdout.write('Speaker identity report\n');
  process.stdout.write(`Thresholds in force: match ${limits.voiceMatchThreshold}, repair ${limits.voiceRepairThreshold},`
    + ` enroll floor ${limits.voiceEnrollFloor}, cluster merge ${limits.speakerClusterMergeThreshold}\n`);
  for (const user of rows) process.stdout.write(`${reportForUser(database, user, limits)}\n`);
}

if (require.main === module) main();

module.exports = { histogram, BUCKETS };
