package schema_test

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
)

func TestEnsurePlaintextLegacyDBUnlockAndVerify(t *testing.T) {
	ctx := context.Background()
	fixture, err := os.ReadFile(filepath.Join("testdata", "bsmc_sample.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	dbPath := filepath.Join(dir, "neorecall.sqlite3")
	keyPath := filepath.Join(dir, "secret.key")

	rawKey := bytes.Repeat([]byte{0x37}, 32)
	if err := os.WriteFile(keyPath, rawKey, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath, fixture, 0o600); err != nil {
		t.Fatal(err)
	}

	if ok, err := schema.IsPlainSQLiteFile(dbPath); err != nil || ok {
		t.Fatalf("expected encrypted DB header, got plain=%v err=%v", ok, err)
	}

	// Wrong key must fail cleanly.
	wrongKey := bytes.Repeat([]byte{0x99}, 32)
	if _, err := schema.DecryptSQLite3MCBytes(fixture, wrongKey); err == nil {
		t.Fatal("expected decryption failure with wrong key")
	}

	converted, err := schema.EnsurePlaintextLegacyDB(ctx, dbPath, keyPath, "", "")
	if err != nil {
		t.Fatalf("EnsurePlaintextLegacyDB failed: %v", err)
	}
	if !converted {
		t.Fatal("expected converted=true for encrypted legacy database")
	}

	if ok, err := schema.IsPlainSQLiteFile(dbPath); err != nil || !ok {
		t.Fatalf("expected plaintext SQLite after conversion, got plain=%v err=%v", ok, err)
	}

	reopened, err := dbx.Open(ctx, dbPath, dbx.Options{})
	if err != nil {
		t.Fatalf("dbx.Open after conversion failed: %v", err)
	}
	defer reopened.Close()
	var username string
	if err := reopened.R.QueryRowContext(ctx, `SELECT username FROM users WHERE id='u-real'`).Scan(&username); err != nil {
		t.Fatalf("query converted row failed: %v", err)
	}
	if username != "real-bsmc-user" {
		t.Fatalf("got username %q, want real-bsmc-user", username)
	}

	// Second call must be a no-op.
	converted2, err := schema.EnsurePlaintextLegacyDB(ctx, dbPath, keyPath, "", "")
	if err != nil || converted2 {
		t.Fatalf("expected second call to be no-op, got converted=%v err=%v", converted2, err)
	}
}

func TestLegacyEncryptedWALRequiresNodeModule(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "neorecall.sqlite3")
	keyPath := filepath.Join(dir, "secret.key")
	fixture, err := os.ReadFile(filepath.Join("testdata", "bsmc_sample.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath, fixture, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, bytes.Repeat([]byte{0x37}, 32), 0600); err != nil {
		t.Fatal(err)
	}
	wal := []byte("pending frames")
	if err := os.WriteFile(dbPath+"-wal", wal, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := schema.EnsurePlaintextLegacyDB(context.Background(), dbPath, keyPath, filepath.Join(dir, "missing"), filepath.Join(dir, "missing-home")); err == nil {
		t.Fatal("expected error when WAL cannot be decrypted")
	}
	got, err := os.ReadFile(dbPath + "-wal")
	if err != nil || !bytes.Equal(got, wal) {
		t.Fatalf("WAL changed: %q, %v", got, err)
	}
	got, err = os.ReadFile(dbPath)
	if err != nil || !bytes.Equal(got, fixture) {
		t.Fatalf("database changed: %v", err)
	}
}

// An upgrade from the Node.js server ends encrypted again, in one step.
func TestOpenTurnsANodeEncryptedDatabaseIntoOurEncryption(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	paths := config.Paths{Home: dir, Database: filepath.Join(dir, "neorecall.sqlite3"), SecretKey: filepath.Join(dir, "secret.key")}
	fixture, err := os.ReadFile(filepath.Join("testdata", "bsmc_sample.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.Database, fixture, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.SecretKey, bytes.Repeat([]byte{0x37}, 32), 0o600); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		db, err := schema.Open(ctx, paths, "")
		if err != nil {
			t.Fatal(err)
		}
		var username string
		if err := db.R.QueryRowContext(ctx, `SELECT username FROM users WHERE id='u-real'`).Scan(&username); err != nil || username != "real-bsmc-user" {
			t.Fatal(username, err)
		}
		db.Close()
		raw, err := os.ReadFile(paths.Database)
		if err != nil || bytes.Contains(raw, []byte("real-bsmc-user")) || bytes.HasPrefix(raw, []byte("SQLite format 3")) {
			t.Fatal("not encrypted at rest", err)
		}
	}
}
