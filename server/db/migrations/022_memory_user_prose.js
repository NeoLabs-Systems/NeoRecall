'use strict';

function up(db) {
  // When someone renames a card, changes its emoji or corrects its type, that
  // is a decision. Consolidation may later extend the same occasion with new
  // material, and it must not silently rewrite the wording the person chose.
  // Existing rows stay NULL: nothing has been edited by hand yet.
  db.exec(`
    ALTER TABLE memories ADD COLUMN prose_edited_at TEXT;
  `);
}

module.exports = { up };
