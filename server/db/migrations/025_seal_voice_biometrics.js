'use strict';

// Encrypts enrolled voice biometrics at rest: voiceprint centroids and the
// speaker preview clips. These are the only rows in the database that identify a
// specific person by their voice, so they get the same AES-256-GCM treatment as
// provider credentials rather than sitting in the clear next to the transcripts.
//
// One-shot and idempotent: `isSealed` skips rows a partially applied run already
// converted, so re-running after an interruption is safe.
const { sealBuffer, isSealed } = require('../../utils/crypto');

function up(db) {
  const centroids = db.prepare('SELECT id, centroid_embedding FROM voiceprints WHERE centroid_embedding IS NOT NULL').all();
  const updateCentroid = db.prepare('UPDATE voiceprints SET centroid_embedding=? WHERE id=?');
  for (const row of centroids) {
    if (!isSealed(row.centroid_embedding)) updateCentroid.run(sealBuffer(row.centroid_embedding), row.id);
  }

  const previews = db.prepare('SELECT voiceprint_id, audio FROM speaker_previews WHERE audio IS NOT NULL').all();
  const updatePreview = db.prepare('UPDATE speaker_previews SET audio=? WHERE voiceprint_id=?');
  for (const row of previews) {
    if (!isSealed(row.audio)) updatePreview.run(sealBuffer(row.audio), row.voiceprint_id);
  }
}

module.exports = { up };
