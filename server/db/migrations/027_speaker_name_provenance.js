'use strict';

function up(db) {
  db.exec(`
    ALTER TABLE voiceprints ADD COLUMN display_name_source TEXT
      CHECK (display_name_source IS NULL OR display_name_source IN ('inferred','manual'));
    UPDATE voiceprints SET display_name_source='inferred' WHERE display_name IS NOT NULL;
  `);
}

module.exports = { up };
