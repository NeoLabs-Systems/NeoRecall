// Package schema owns NeoRecall's SQLite layout and versioned migrations.
//
// baseline.sql is the schema produced by Node migrations 001..037 (excluding
// legacy sqlite-vec virtual tables, replaced by Go LSH + cosine search).
package schema

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
)

//go:embed baseline.sql
var baseline string

//go:embed USER_VERSION
var userVersionText string

// BaselineVersion is the Node-era migration version encoded in baseline.sql.
func BaselineVersion() int {
	n, err := strconv.Atoi(strings.TrimSpace(userVersionText))
	if err != nil {
		panic("schema: USER_VERSION is not a number: " + err.Error())
	}
	return n
}

// Steps returns the ordered migrations. Entries 0..BaselineVersion()-1 are
// satisfied by baseline.sql; subsequent Go migrations run via dbx.Migrate.
func Steps() []dbx.Step {
	steps := make([]dbx.Step, BaselineVersion(), BaselineVersion()+4)
	for i := range steps {
		steps[i] = func(context.Context, *sql.Tx) error { return nil }
	}
	// Step 38: Pure-Go locality-sensitive embedding bands replacing CGo vec_search.
	steps = append(steps, func(ctx context.Context, tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS search_embedding_bands (
	document_id INTEGER NOT NULL REFERENCES search_documents(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	dimension INTEGER NOT NULL,
	index_version INTEGER NOT NULL,
	band_index INTEGER NOT NULL,
	band_value INTEGER NOT NULL,
	updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
	PRIMARY KEY (document_id, band_index)
);
CREATE INDEX IF NOT EXISTS idx_search_embedding_bands_lookup
	ON search_embedding_bands(user_id, dimension, index_version, band_index, band_value);
`)
		return err
	})
	return steps
}

// Ensure prepares db for use: an empty DB gets baseline.sql, an existing Node
// DB at schema_migrations version >= BaselineVersion syncs PRAGMA user_version,
// existing tables/columns are verified, and Go migrations run via dbx.Migrate.
func Ensure(ctx context.Context, db *sql.DB) error {
	empty, err := isEmpty(ctx, db)
	if err != nil {
		return err
	}
	if empty {
		if err := applyBaseline(ctx, db); err != nil {
			return err
		}
	} else {
		if err := migrateNode36(ctx, db); err != nil {
			return err
		}
		if err := syncLegacyUserVersion(ctx, db); err != nil {
			return err
		}
		if err := Verify(ctx, db); err != nil {
			return err
		}
	}
	return dbx.Migrate(ctx, db, Steps())
}

// migrateNode36 applies the final Node migration before the Go baseline.
func migrateNode36(ctx context.Context, db *sql.DB) (retErr error) {
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	var uv, exists int
	if err := conn.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&uv); err != nil {
		return err
	}
	if uv != 0 {
		return nil
	}
	if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='schema_migrations'`).Scan(&exists); err != nil || exists == 0 {
		return err
	}
	var count int
	var min, max sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT COUNT(*), MIN(version), MAX(version) FROM schema_migrations`).Scan(&count, &min, &max); err != nil {
		return err
	}
	if !min.Valid || min.Int64 != 1 || !max.Valid || max.Int64 != 36 || count != 36 {
		return nil
	}
	var fk int
	if err := conn.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&fk); err != nil {
		return err
	}
	if fk != 0 {
		if _, err := conn.ExecContext(ctx, `PRAGMA foreign_keys=OFF`); err != nil {
			return err
		}
		defer func() {
			if _, err := conn.ExecContext(context.Background(), `PRAGMA foreign_keys=ON`); err != nil && retErr == nil {
				retErr = err
			}
		}()
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `
CREATE TABLE cloud_accounts_new (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
 type TEXT NOT NULL CHECK (type IN ('nextcloud','neocloud')), base_url TEXT NOT NULL,
 username TEXT NOT NULL, secret_encrypted TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'NeoRecall',
 audio_enabled INTEGER NOT NULL DEFAULT 0 CHECK (audio_enabled IN (0,1)),
 data_backup_enabled INTEGER NOT NULL DEFAULT 0 CHECK (data_backup_enabled IN (0,1)),
 status TEXT NOT NULL DEFAULT 'connected' CHECK (status IN ('connected','error')),
 last_error TEXT, last_audio_upload_at TEXT, last_data_backup_at TEXT,
 remote_device_id TEXT, quota_used INTEGER, quota_limit INTEGER,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
INSERT INTO cloud_accounts_new (id,user_id,type,base_url,username,secret_encrypted,folder,audio_enabled,data_backup_enabled,status,last_error,last_audio_upload_at,last_data_backup_at,created_at,updated_at)
 SELECT id,user_id,type,base_url,username,secret_encrypted,folder,audio_enabled,data_backup_enabled,status,last_error,last_audio_upload_at,last_data_backup_at,created_at,updated_at FROM cloud_accounts;
DROP TABLE cloud_accounts;
ALTER TABLE cloud_accounts_new RENAME TO cloud_accounts;
ALTER TABLE cloud_archive_items ADD COLUMN remote_upload_id TEXT;
ALTER TABLE cloud_archive_items ADD COLUMN captured_at TEXT;
INSERT INTO schema_migrations(version,name) VALUES (37,'037_cloud_neocloud.js');
`)
	if err != nil {
		return fmt.Errorf("schema: migrate Node version 36: %w", err)
	}
	rows, err := tx.QueryContext(ctx, `PRAGMA foreign_key_check`)
	if err != nil {
		return err
	}
	violation := rows.Next()
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if violation {
		return fmt.Errorf("schema: Node migration 37 would leave foreign key violations")
	}
	return tx.Commit()
}

func isEmpty(ctx context.Context, db *sql.DB) (bool, error) {
	var n int
	err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'`).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("schema: inspect database: %w", err)
	}
	return n == 0, nil
}

func syncLegacyUserVersion(ctx context.Context, db *sql.DB) error {
	var uv int
	if err := db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&uv); err != nil {
		return err
	}
	if uv > 0 {
		return nil
	}
	// Node databases tracked versions in schema_migrations without setting PRAGMA user_version.
	var hasTable int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='schema_migrations'`).Scan(&hasTable); err != nil {
		return err
	}
	if hasTable == 0 {
		return nil
	}
	var maxVer sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&maxVer); err != nil {
		return err
	}
	if maxVer.Valid && int(maxVer.Int64) >= BaselineVersion() {
		_, err := db.ExecContext(ctx, fmt.Sprintf(`PRAGMA user_version = %d`, BaselineVersion()))
		return err
	}
	return nil
}

func applyBaseline(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("schema: begin: %w", err)
	}
	if _, err := tx.ExecContext(ctx, baseline); err != nil {
		tx.Rollback()
		return fmt.Errorf("schema: apply baseline: %w", err)
	}
	if _, err := tx.ExecContext(ctx, fmt.Sprintf(`PRAGMA user_version = %d`, BaselineVersion())); err != nil {
		tx.Rollback()
		return fmt.Errorf("schema: record version: %w", err)
	}
	return tx.Commit()
}

// Verify checks that an existing database has every baseline table and column.
func Verify(ctx context.Context, db *sql.DB) error {
	var version int
	if err := db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil {
		return fmt.Errorf("schema: read user_version: %w", err)
	}
	if version < BaselineVersion() {
		return fmt.Errorf("schema: database is at version %d, this build needs %d; upgrade with the prior release first", version, BaselineVersion())
	}

	ref, err := sql.Open("sqlite", "file::memory:")
	if err != nil {
		return err
	}
	defer ref.Close()
	ref.SetMaxOpenConns(1)
	if _, err := ref.ExecContext(ctx, baseline); err != nil {
		return fmt.Errorf("schema: build reference: %w", err)
	}
	want, err := columns(ctx, ref, nil)
	if err != nil {
		return err
	}
	have, err := columns(ctx, db, want)
	if err != nil {
		return err
	}

	var problems []string
	for table, cols := range want {
		got, ok := have[table]
		if !ok {
			problems = append(problems, "missing table "+table)
			continue
		}
		for c := range cols {
			if !got[c] {
				problems = append(problems, "missing column "+table+"."+c)
			}
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("schema: incompatible database: %s", strings.Join(problems, ", "))
	}
	return nil
}

func columns(ctx context.Context, db *sql.DB, required map[string]map[string]bool) (map[string]map[string]bool, error) {
	rows, err := db.QueryContext(ctx, `SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		return nil, err
	}
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			return nil, err
		}
		names = append(names, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make(map[string]map[string]bool, len(names))
	for _, table := range names {
		// Ignore tables outside the baseline. In particular, opening an old
		// sqlite-vec virtual table requires an extension the Go runtime lacks.
		if required != nil {
			if _, ok := required[table]; !ok {
				continue
			}
		}
		colRows, err := db.QueryContext(ctx, fmt.Sprintf(`PRAGMA table_info("%s")`, strings.ReplaceAll(table, `"`, `""`)))
		if err != nil {
			return nil, err
		}
		cols := map[string]bool{}
		for colRows.Next() {
			var cid int
			var name, colType string
			var notNull, pk int
			var dflt sql.NullString
			if err := colRows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
				colRows.Close()
				return nil, err
			}
			cols[name] = true
		}
		colRows.Close()
		out[table] = cols
	}
	return out, nil
}
