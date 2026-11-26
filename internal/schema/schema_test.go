package schema

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
)

func TestEnsureFreshAndIdempotent(t *testing.T) {
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "neorecall.sqlite3")
	db, err := dbx.Open(ctx, dbPath, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := Ensure(ctx, db.W); err != nil {
		t.Fatalf("first Ensure failed: %v", err)
	}
	if err := Ensure(ctx, db.W); err != nil {
		t.Fatalf("second Ensure failed: %v", err)
	}

	var uv int
	if err := db.R.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&uv); err != nil {
		t.Fatal(err)
	}
	if uv != len(Steps()) {
		t.Fatalf("expected user_version %d, got %d", len(Steps()), uv)
	}
	var bandsTable string
	if err := db.R.QueryRowContext(ctx, `SELECT name FROM sqlite_schema WHERE type='table' AND name='search_embedding_bands'`).Scan(&bandsTable); err != nil {
		t.Fatalf("missing search_embedding_bands: %v", err)
	}
}

func TestUpgradeNode36PreservesCloudData(t *testing.T) {
	ctx := context.Background()
	db, err := dbx.Open(ctx, filepath.Join(t.TempDir(), "legacy.sqlite3"), dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	legacy := strings.Replace(baseline, "type IN ('nextcloud','neocloud')", "type IN ('nextcloud')", 1)
	legacy = strings.Replace(legacy, "      remote_device_id TEXT,\n      quota_used INTEGER,\n      quota_limit INTEGER,\n", "", 1)
	legacy = strings.Replace(legacy, ", remote_upload_id TEXT, captured_at TEXT", "", 1)
	if legacy == baseline {
		t.Fatal("legacy fixture was not constructed")
	}
	if _, err := db.W.ExecContext(ctx, legacy); err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= 36; i++ {
		if _, err := db.W.ExecContext(ctx, `INSERT INTO schema_migrations(version,name) VALUES (?,?)`, i, "legacy"); err != nil {
			t.Fatal(err)
		}
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO users(id,username,password_hash) VALUES('u','user','hash');
INSERT INTO cloud_accounts(id,user_id,type,base_url,username,secret_encrypted) VALUES('a','u','nextcloud','url','name','secret');
INSERT INTO cloud_archive_items(id,user_id,account_id,kind,remote_path) VALUES('item','u','a','data','path');`)
	if err != nil {
		t.Fatal(err)
	}
	if err := Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	if err := Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	var account, secret string
	if err := db.R.QueryRowContext(ctx, `SELECT account_id FROM cloud_archive_items WHERE id='item'`).Scan(&account); err != nil || account != "a" {
		t.Fatalf("archive: %q %v", account, err)
	}
	if err := db.R.QueryRowContext(ctx, `SELECT secret_encrypted FROM cloud_accounts WHERE id='a'`).Scan(&secret); err != nil || secret != "secret" {
		t.Fatalf("account: %q %v", secret, err)
	}
	var version int
	if err := db.R.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil || version != len(Steps()) {
		t.Fatalf("version: %d %v", version, err)
	}
}
