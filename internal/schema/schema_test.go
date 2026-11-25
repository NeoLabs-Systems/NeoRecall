package schema

import (
	"context"
	"path/filepath"
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
