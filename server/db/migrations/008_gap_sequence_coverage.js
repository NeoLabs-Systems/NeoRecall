'use strict';

function up(db) {
  db.exec(`
    ALTER TABLE recording_gaps ADD COLUMN start_sequence INTEGER;
    ALTER TABLE recording_gaps ADD COLUMN end_sequence INTEGER;
    CREATE INDEX idx_recording_gaps_source_sequence ON recording_gaps(source_id, start_sequence, end_sequence);
  `);
}

module.exports = { up };
