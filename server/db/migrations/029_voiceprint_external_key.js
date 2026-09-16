'use strict';

// A durable link between a voice and an identity the recording already knew.
//
// Some audio arrives with the answer attached. A capture path that receives one
// stream per participant knows exactly whose stream it is, and reconstructing
// that from the sound of the voice is both slower and worse than the fact it was
// handed. `external_key` is where that fact is kept — an opaque string the
// source chooses, scoped to the user, with no meaning to anything here beyond
// "the same key is the same person".
//
// The name that arrives alongside it is a different kind of claim and is stored
// as `display_name_source='inferred'`: an account name is a guess at what a
// person is called, and the user renaming them must win. The key is the durable
// half and never changes.
//
// The index is partial so the many voices that have no external identity do not
// collide with each other on NULL, and so the intent is legible: at most one
// profile per user per external identity.
function up(db) {
  db.exec(`
    ALTER TABLE voiceprints ADD COLUMN external_key TEXT;
    CREATE UNIQUE INDEX idx_voiceprints_external ON voiceprints(user_id, external_key)
      WHERE external_key IS NOT NULL;
  `);
}

module.exports = { up };
