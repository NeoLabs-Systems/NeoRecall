'use strict';

function up(db) {
  // SQLite cannot alter CHECK constraints in place; recreate devices with appliance support.
  db.exec(`
    CREATE TABLE devices_new (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      client_uuid TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('browser','desktop','mobile','import','wearable','appliance')),
      capabilities_json TEXT NOT NULL DEFAULT '{}',
      clock_offset_ms REAL,
      clock_rtt_ms REAL,
      last_heartbeat_at TEXT,
      revoked_at TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, client_uuid)
    );
    INSERT INTO devices_new
      (id,user_id,client_uuid,name,platform,kind,capabilities_json,clock_offset_ms,clock_rtt_ms,last_heartbeat_at,revoked_at,created_at)
      SELECT id,user_id,client_uuid,name,platform,kind,capabilities_json,clock_offset_ms,clock_rtt_ms,last_heartbeat_at,revoked_at,created_at
      FROM devices;
    DROP TABLE devices;
    ALTER TABLE devices_new RENAME TO devices;
  `);
}

module.exports = { up, rebuildsReferencedTable: true };
