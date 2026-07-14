'use strict';

function up(db) {
  db.exec(`
    CREATE TABLE search_documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('segment','memory','mini_memory','daily_summary')),
      source_id TEXT NOT NULL,
      title TEXT,
      body TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      importance REAL NOT NULL DEFAULT 0,
      text_hash TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      UNIQUE(user_id, kind, source_id)
    );
    CREATE INDEX idx_search_documents_user_kind ON search_documents(user_id, kind, occurred_at DESC);
    CREATE VIRTUAL TABLE search_fts USING fts5(
      title, body,
      content='search_documents', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER search_documents_ai AFTER INSERT ON search_documents BEGIN
      INSERT INTO search_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;
    CREATE TRIGGER search_documents_ad AFTER DELETE ON search_documents BEGIN
      INSERT INTO search_fts(search_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    END;
    CREATE TRIGGER search_documents_au AFTER UPDATE ON search_documents BEGIN
      INSERT INTO search_fts(search_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
      INSERT INTO search_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
    END;
    CREATE TABLE search_embeddings (
      document_id INTEGER PRIMARY KEY REFERENCES search_documents(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      model_revision TEXT NOT NULL,
      dimensions INTEGER NOT NULL CHECK (dimensions = 384),
      embedding BLOB NOT NULL,
      text_hash TEXT NOT NULL,
      embedded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE VIRTUAL TABLE vec_search USING vec0(
      document_id INTEGER PRIMARY KEY,
      embedding FLOAT[384],
      user_id TEXT PARTITION KEY,
      kind TEXT
    );
  `);
}

module.exports = { up };
