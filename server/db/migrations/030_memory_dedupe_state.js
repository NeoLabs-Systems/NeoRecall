'use strict';

// Which memory cards the duplicate sweep has already judged.
//
// The sweep asks a language model whether two cards describe the same occasion.
// That question costs a request, and its answer does not change when nothing
// about either card has: without a mark, every sweep would re-ask about every
// pair it has already settled, forever. NULL means "never judged", which is
// what every card written before this migration is.

function up(db) {
  db.exec(`
    ALTER TABLE memories ADD COLUMN dedupe_checked_at TEXT;
    CREATE INDEX idx_memories_dedupe_pending ON memories(user_id) WHERE dedupe_checked_at IS NULL;
  `);
}

module.exports = { up };
