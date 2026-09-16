'use strict';

const crypto = require('node:crypto');
const vectors = require('../transcription/speaker_embeddings');
const voiceprintStorage = require('../transcription/voiceprint_storage');
const matching = require('../transcription/speaker_matching');

// When the recording already knows who is speaking.
//
// Identifying a voice by its sound is inference, and inference is what produces
// the same person twice. Some capture paths never needed it: one that receives a
// separate stream per participant is told whose stream it is, and every part of
// this pipeline that then works it out from the audio is not only slower but
// worse than the fact it was handed at the start.
//
// A source declares that fact by putting `speaker: { key, name }` in the
// metadata it already sends when it registers. Nothing here knows or cares what
// produced it — no integration is named in this file, and none should be. A
// source that knows, says so; one that does not, says nothing and is matched
// acoustically exactly as before. That is the whole contract, and it is why this
// works the same for a chat bot, a per-participant recorder, or a client that
// simply knows it is a single person's headset.
//
// The key is scoped to the user and otherwise opaque. Callers should namespace
// it ("<source>:<id>") so two sources cannot collide, but nothing depends on it.

// Reads a source's declaration. Returns null for the ordinary case of a source
// that has nothing to say about who is speaking.
function declaredSpeaker(database, sourceId) {
  if (!sourceId) return null;
  const row = database.prepare('SELECT metadata_json FROM recording_sources WHERE id=?').get(sourceId);
  if (!row || !row.metadata_json) return null;
  let metadata;
  try {
    metadata = JSON.parse(row.metadata_json);
  } catch {
    // Metadata is client-supplied and best-effort by design. Malformed JSON must
    // never fail a transcription.
    return null;
  }
  const speaker = metadata && metadata.speaker;
  if (!speaker || typeof speaker.key !== 'string' || !speaker.key.trim()) return null;
  return {
    key: speaker.key.trim().slice(0, 200),
    name: typeof speaker.name === 'string' && speaker.name.trim() ? speaker.name.trim().slice(0, 120) : null,
  };
}

// The durable voice for a declared identity, created the first time it is seen.
//
// Knowing who somebody is and knowing what they sound like are separate facts
// and are written separately: this establishes the identity with no fingerprint
// at all, and reinforceDeclared below is the only thing that ever gives it one.
// Keeping them apart is what lets a profile exist for a person whose every
// recording so far had somebody else talking over it — correctly named, and
// correctly unable to match anyone by sound until it has heard them alone.
//
// `INSERT ... ON CONFLICT DO NOTHING` rather than a read-then-write, because two
// workers can transcribe two chunks of the same speaker at once and the unique
// index is the only thing that can actually settle which of them wins.
function voiceprintForKey(database, { userId, key, name }) {
  // A profile with nothing behind it needs a centroid column all the same. A
  // zero vector scores against every voice at -1, so it can never be matched by
  // accident before it has heard the person.
  const empty = voiceprintStorage.sealCentroid(new Float32Array(1));
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,external_key,display_name,display_name_source,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?,1,0)
    ON CONFLICT(user_id,external_key) WHERE external_key IS NOT NULL DO NOTHING`)
    .run(crypto.randomUUID(), userId, key, name, name ? 'inferred' : null, empty, matching.modelName);
  const voiceprint = database.prepare('SELECT * FROM voiceprints WHERE user_id=? AND external_key=?').get(userId, key);
  // A name only fills a gap. Once somebody has been named — by the user, or by
  // the model reading a self-introduction out of the transcript — an account
  // name arriving later is the weaker claim and must not overwrite it.
  if (voiceprint && name && !voiceprint.display_name) {
    database.prepare(`UPDATE voiceprints SET display_name=?,display_name_source='inferred',
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND display_name IS NULL`).run(name, voiceprint.id);
    return database.prepare('SELECT * FROM voiceprints WHERE id=?').get(voiceprint.id);
  }
  return voiceprint;
}

// Folds a fresh sample into a declared identity's profile.
//
// This is the part worth having beyond the label: a declared identity is
// labelled speech, which is the one thing acoustic matching never gets. A
// profile built from it recognises the same person on every other source — the
// room recorder, the pendant, the laptop — where nothing declares anything.
//
// Withheld when the chunk carried more than one voice. The declaration says
// whose stream this is, and it is trusted for the label; but a second person
// audible in the room behind an open microphone is on that stream too, and
// letting their speech into the profile would corrupt the very thing that makes
// the declaration valuable elsewhere.
function reinforceDeclared(database, voiceprint, embedding, { exclusive }) {
  if (!exclusive || !embedding || !voiceprint) return voiceprint;
  const stored = voiceprintStorage.readCentroid(voiceprint.centroid_embedding);
  const known = stored && stored.length === embedding.length && voiceprint.sample_count > 0;
  const centroid = known ? vectors.updateCentroid(stored, voiceprint.sample_count, embedding) : vectors.normalize(embedding);
  database.prepare(`UPDATE voiceprints SET centroid_embedding=?,embedding_model=?,embedding_dimensions=?,
    sample_count=sample_count+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
    .run(voiceprintStorage.sealCentroid(centroid), matching.modelName, embedding.length, voiceprint.id);
  return database.prepare('SELECT * FROM voiceprints WHERE id=?').get(voiceprint.id);
}

// The session-scoped voice a declared person speaks as.
//
// Not resolved acoustically, and that is the point. Two people who happen to
// sound alike would otherwise land in the same session cluster and share a
// label, however clearly the recordings named them apart — the declaration would
// fix the durable profile and still lose the transcript. So a declared stream
// gets a cluster of its own, found by the person it already belongs to and
// created if there is none. One person, one voice, per recording, decided by
// what the source said rather than by a cosine.
function clusterForDeclared(database, { userId, sessionId, voiceprintId, embedding }) {
  const existing = database.prepare(`SELECT sc.* FROM speaker_clusters sc
    JOIN speaker_turns st ON st.cluster_id=sc.id AND st.user_id=sc.user_id
    WHERE sc.user_id=? AND sc.session_id=? AND st.voiceprint_id=?
    GROUP BY sc.id ORDER BY COUNT(*) DESC,sc.local_ordinal LIMIT 1`).get(userId, sessionId, voiceprintId);
  if (existing) return existing;
  return matching.createCluster(database, { userId, sessionId, embedding });
}

module.exports = { declaredSpeaker, voiceprintForKey, reinforceDeclared, clusterForDeclared };
