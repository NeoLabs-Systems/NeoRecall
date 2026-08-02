'use strict';

function up(db) {
  // One emoji represents the memory's occasion in the consumer UI (LLM-chosen
  // at consolidation time). Existing rows stay NULL and fall back by type.
  db.exec(`
    ALTER TABLE memories ADD COLUMN emoji TEXT;
  `);
}

module.exports = { up };
