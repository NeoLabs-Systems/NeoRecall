'use strict';

// A validation failure already carries a specific, human-written reason at its
// throw site — "Conversation sections must cover each recording stream without
// gaps or overlaps.", "A memory cited a source outside a memory-worthy
// conversation section." — but only its error_code reached storage. Diagnosing
// a real failure meant re-sending the same paid request just to see the message
// a second time. error_message keeps the reason the first time.

function up(db) {
  db.exec(`
    ALTER TABLE consolidation_runs ADD COLUMN error_message TEXT;
  `);
}

module.exports = { up };
