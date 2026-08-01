'use strict';

const matching = require('../../transcription/speaker_matching');

// Names a voice from evidence the consolidation model already produced, with no
// separate AI request. Consolidation already reads the whole transcript with
// speaker labels attached and already extracts person entities; when the
// transcript itself identifies which speaker label a person was heard speaking
// as (a self-introduction, or another speaker naming them), the model reports
// that link on the entity as `speakerAlias`. This turns that link into a name
// on the voiceprint, the same durable identity the Speakers screen and manual
// rename already operate on — so an automatically identified speaker behaves
// exactly like a manually named one from then on, including remaining fully
// correctable through the existing rename/merge UI if the model got it wrong.
//
// Deliberately best-effort: an entity with no speakerAlias, a speaker label
// consolidation did not use in this batch, or a cluster with no voiceprint yet
// (recurring speaker matching never ran for it) are all silently skipped. This
// enrichment must never fail or destabilize consolidation itself.

/// Links every person entity consolidation identified by voice to the
/// voiceprint that cluster currently resolves to.
///
/// `entities` is the model's output.entities array (post schema validation).
/// `entityIds` maps each entity's response-local `ref` to its durable entities
/// row id, already resolved by the caller. `clusterIdsByAlias` maps the speaker
/// labels this consolidation batch used (e.g. "speaker2") back to the durable
/// speaker_clusters id they stood for.
function linkEntitiesToSpeakers(database, userId, entities, entityIds, clusterIdsByAlias) {
  const linked = [];
  for (const entity of entities) {
    if (entity.kind !== 'person' || !entity.speakerAlias) continue;
    const clusterId = clusterIdsByAlias.get(entity.speakerAlias);
    if (!clusterId) continue;
    const voiceprint = matching.stickyVoiceprintForCluster(database, { userId, clusterId });
    if (!voiceprint) continue;
    const entityId = entityIds.get(entity.ref);
    if (!entityId) continue;
    // COALESCE never overwrites a name the user already set manually.
    const changes = database.prepare(`UPDATE voiceprints SET entity_id=?,display_name=COALESCE(display_name,?),
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`)
      .run(entityId, entity.displayName || entity.canonicalNameEn, voiceprint.id, userId).changes;
    if (changes) linked.push({ voiceprintId: voiceprint.id, entityId });
  }
  return linked;
}

module.exports = { linkEntitiesToSpeakers };
