'use strict';

const clustering = require('./clustering');
const evidence = require('./evidence');
const vectors = require('../transcription/speaker_embeddings');
const matching = require('../transcription/speaker_matching');
const membership = require('../services/conversations/conversation_membership_service');
const processingSettings = require('../services/settings/processing_settings_service');
const settings = require('../services/settings/settings_service');
const { createLogger } = require('../utils/logger');

const logger = createLogger('speaker-resolution');

// A conversation heard by more voices than this is not a conversation, it is a
// symptom. Grouping this many measured against 192-dimensional vectors takes
// around half a second, which is affordable for a background job and pointless
// work on a conversation that is already wrong; the limit exists so the worst
// case is a stated refusal rather than something discovered in production.
const MAXIMUM_VOICES = 200;

// Resolving who spoke in a conversation, once the conversation is over.
//
// While a recording runs, every speaker decision is made from one chunk against
// whatever came before it, because that is all there is. Two costs follow. A
// voice re-segmented at a chunk boundary can drift below the matching bar and
// start a second identity, and a fingerprint pooled from a few seconds is often
// too little speech to enroll anyone at all — so its turns end up attached to no
// durable person, and rebuildConversationSpeakers, having nothing to group them
// by, gives each one its own Speaker N. That is the "one person, three labels"
// report, and neither cost is a threshold that could be tuned away: they are
// both consequences of deciding early.
//
// By the time a conversation closes, the constraint is gone. Every voice in it
// is on the table, and the pooled speech behind each one is conversation-scale
// rather than chunk-scale, which clears the enrollment floor that per-chunk
// speech usually cannot. So this re-asks the question with all the evidence,
// and the answer replaces the provisional one.
//
// Timing is what makes rewriting labels safe: consolidation only ever reads
// conversations in the closed state, at least one scheduler tick later, and is
// gated against conversations still waiting on this pass. Corrections therefore
// land before anything reads a speaker label, rather than contradicting
// something already written.

// Every name the user has attached to a voice heard in this conversation, read
// in one query. Reading them per comparison would mean a database round trip
// inside the clustering loop, which asks about pairs of pairs and would turn a
// handful of voices into thousands of queries.
function claimedIdentities(database, items) {
  const ids = [...new Set(items.flatMap((item) => [...item.voiceprintIds]))];
  if (!ids.length) return new Map();
  const rows = database.prepare(`SELECT id,display_name,display_name_source,entity_id FROM voiceprints
    WHERE id IN (${ids.map(() => '?').join(',')})`).all(...ids);
  // Only a name the user stands behind counts. A name the model inferred is a
  // reading of the transcript, and this pass is allowed to correct it.
  return new Map(rows
    .filter((row) => row.display_name_source === 'manual' || row.entity_id)
    .map((row) => [row.id, row]));
}

// A merge must never quietly undo a naming the user did by hand, and two
// clusters carrying different named people is the strongest possible statement
// that they are not the same voice — stronger than any similarity score.
function namedDifferently(claimed, first, second) {
  const names = (item) => [...item.voiceprintIds].map((id) => claimed.get(id)).filter(Boolean);
  const left = names(first);
  const right = names(second);
  if (!left.length || !right.length) return false;
  return left.some((one) => right.some((other) => (one.entity_id && other.entity_id && one.entity_id !== other.entity_id)
    || (one.display_name && other.display_name && one.display_name !== other.display_name)));
}

// Which pairs of voices are known not to be the same person, worked out once.
//
// The clustering loop asks this repeatedly — for every candidate pair, and for
// every member of a group once groups start forming — so answering it by
// comparing time spans and querying names each time turns a linear amount of
// evidence into a cubic amount of work. It is a fixed property of the
// conversation, so it is computed here and then only looked up.
function forbiddenPairs(database, items, minimumOverlapMs) {
  const claimed = claimedIdentities(database, items);
  const pairs = new Set();
  for (let left = 0; left < items.length; left += 1) {
    for (let right = left + 1; right < items.length; right += 1) {
      // Two streams a source declared to be different people are different
      // people, whatever they sound like — that beats similarity, and it beats
      // overlap agreeing with it too.
      if (evidence.declaredSame(items[left], items[right])) continue;
      if (evidence.declaredDifferently(items[left], items[right])
        || evidence.overlaps(items[left], items[right], minimumOverlapMs)
        || namedDifferently(claimed, items[left], items[right])) {
        pairs.add(`${items[left].id} ${items[right].id}`);
        pairs.add(`${items[right].id} ${items[left].id}`);
      }
    }
  }
  return pairs;
}

// Voices the recording itself says are one person, grouped before similarity is
// consulted at all. A declared identity is not evidence to be weighed against a
// cosine score; it is the answer, and clustering only has to handle what is left
// over. Two clusters on one declared stream are always the same person — that is
// what the stream means — so a fingerprint too poor to match cannot split them.
function groupByDeclaration(items, groups) {
  const byKey = new Map();
  const merged = [];
  for (const group of groups) {
    const keys = new Set(group.memberIds.flatMap((id) => {
      const item = items.find((candidate) => candidate.id === id);
      return item ? [...item.declaredKeys] : [];
    }));
    const key = keys.size === 1 ? [...keys][0] : null;
    if (!key) { merged.push(group); continue; }
    const existing = byKey.get(key);
    if (existing) existing.memberIds.push(...group.memberIds);
    else { const copy = { id: group.id, memberIds: [...group.memberIds] }; byKey.set(key, copy); merged.push(copy); }
  }
  return merged;
}

// The whole group's speech as one fingerprint, weighted so a voice heard for a
// minute counts for more than one heard for a second.
function pooledEmbedding(items) {
  const contributors = items.filter((item) => item.embeddings.length);
  if (!contributors.length) return null;
  const dimensions = contributors[0].embeddings[0].length;
  const total = new Float32Array(dimensions);
  let weight = 0;
  for (const item of contributors) {
    const share = Math.max(1, item.speechMs) / item.embeddings.length;
    for (const embedding of item.embeddings) {
      if (embedding.length !== dimensions) continue;
      const unit = vectors.normalize(embedding);
      for (let index = 0; index < dimensions; index += 1) total[index] += unit[index] * share;
      weight += share;
    }
  }
  return weight ? vectors.normalize(total) : null;
}

// Folds a group's clusters together where that is structurally possible.
//
// Only within one session. speaker_clusters is unique on (session_id,
// local_ordinal) and the live resolver searches for a cluster by session, so a
// row moved out of its session becomes invisible to the recording that is still
// producing it: the next chunk mints a replacement, this pass merges it again,
// and the two never stop. Across sessions the same voice simply gets the same
// voiceprint, which rebuildConversationSpeakers already collapses into one
// label — the visible outcome is identical and nothing is destroyed.
function mergeWithinSessions(database, userId, items) {
  const bySession = new Map();
  for (const item of items) {
    if (!bySession.has(item.sessionId)) bySession.set(item.sessionId, []);
    bySession.get(item.sessionId).push(item);
  }
  let merged = 0;
  const survivors = [];
  for (const group of bySession.values()) {
    const rows = group
      .map((item) => database.prepare('SELECT * FROM speaker_clusters WHERE id=? AND user_id=?').get(item.id, userId))
      .filter(Boolean)
      .sort((left, right) => left.local_ordinal - right.local_ordinal);
    if (!rows.length) continue;
    let target = rows[0];
    for (const source of rows.slice(1)) {
      target = matching.mergeClusters(database, { userId, target, source });
      merged += 1;
    }
    survivors.push(target.id);
  }
  return { merged, survivors };
}

// Re-resolves every voice in one conversation from the whole conversation's
// evidence. Idempotent: a second run finds the groups already merged and the
// voiceprints already assigned, and changes nothing.
//
// Its effects are deliberately not confined to this conversation. Session
// clusters outlive a single conversation, so folding two of them together
// corrects every conversation that referenced either — mergeClusters rebuilds
// those itself.
function resolveConversation(database, userId, conversationId) {
  const limits = processingSettings.get();
  const recurringMatching = settings.get(userId).recurringSpeakerMatching;
  // Reading and grouping happen outside the write transaction below.
  //
  // Comparing a long conversation's voices takes a measurable fraction of a
  // second, and SQLite has one writer: holding the lock for that would stall the
  // transcription worker mid-recording, on the path that has audio waiting on a
  // receipt before it may be deleted. Nothing here writes, and the decision is
  // re-checked against live rows when it is applied — a cluster that has since
  // been merged away is skipped, and a turn that has since been attached to a
  // person is left alone — so working from a slightly older read costs at worst
  // one skipped merge, which the next run makes again.
  const items = evidence.collect(database, userId, conversationId);
  if (items.length > MAXIMUM_VOICES) {
    logger.warn('Skipped speaker resolution for an implausibly crowded conversation', {
      userId, conversationId, voices: items.length, limit: MAXIMUM_VOICES,
    });
    return { skipped: 'too_many_voices', voices: items.length };
  }
  if (!items.length) return { voices: 0, groups: 0, mergedClusters: 0, assignedTurns: 0 };

  const byId = new Map(items.map((item) => [item.id, item]));
  const blocked = forbiddenPairs(database, items, limits.speakerMinimumTurnMs);
  const forbidden = (first, second) => blocked.has(`${first} ${second}`);
  const groups = groupByDeclaration(items, clustering.cluster(items, {
    threshold: limits.speakerClusterMergeThreshold,
    margin: limits.speakerClusterMargin,
    forbidden,
  }));

  return database.transaction(() => apply({
    database, userId, conversationId, items, byId, groups, forbidden, recurringMatching,
  })).immediate();
}

// Writes the decision. Everything expensive already happened; this is the part
// that needs the lock, and it is deliberately short.
function apply({ database, userId, conversationId, items, byId, groups, forbidden, recurringMatching }) {
  let mergedClusters = 0;
  let assignedTurns = 0;
  // Which voice each group settled on, so a later group known to be a different
  // person cannot be handed the same one. Keeping two clusters apart is only
  // half the constraint: matching them to one voiceprint afterwards gives them a
  // shared label regardless, and the evidence that they are two people — hearing
  // them speak at once — is thrown away at the last step.
  const assignedByGroup = new Map();
  for (const group of groups) {
    const members = group.memberIds.map((id) => byId.get(id)).filter(Boolean);
    if (!members.length) continue;
    const { merged, survivors } = mergeWithinSessions(database, userId, members);
    mergedClusters += merged;
    if (!recurringMatching) continue;
    const embedding = pooledEmbedding(members);
    if (!embedding) continue;
    const speechMs = members.reduce((sum, item) => sum + item.speechMs, 0);
    const excluded = new Set();
    for (const [otherId, voiceprintId] of assignedByGroup) {
      const other = groups.find((candidate) => candidate.id === otherId);
      if (other && other.memberIds.some((left) => group.memberIds.some((right) => forbidden(left, right)))) {
        excluded.add(voiceprintId);
      }
    }
    // The existing resolver, given evidence it never sees online. Its rules are
    // unchanged — the sticky assignment, the refusal to guess, the enrollment
    // floor — but conversation-scale speech is what finally satisfies them.
    const voiceprint = matching.resolveVoiceprint(database, {
      userId, clusterId: survivors[0] || null, embedding, enabled: true, speechMs, excluded,
    });
    if (!voiceprint || !survivors.length) continue;
    assignedByGroup.set(group.id, voiceprint.id);
    const placeholders = survivors.map(() => '?').join(',');
    // Only turns that resolved to nobody. An existing assignment may be what a
    // name the user typed is hanging from, and this pass has no standing to
    // move it.
    assignedTurns += database.prepare(`UPDATE speaker_turns SET voiceprint_id=?
      WHERE user_id=? AND voiceprint_id IS NULL AND cluster_id IN (${placeholders})`)
      .run(voiceprint.id, userId, ...survivors).changes;
  }

  membership.rebuildConversationSpeakers(database, userId, conversationId);
  return { voices: items.length, groups: groups.length, mergedClusters, assignedTurns };
}


module.exports = { resolveConversation, MAXIMUM_VOICES };
