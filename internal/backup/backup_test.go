package backup_test

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/filebox"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
)

func TestBackupCreatePruneAndRestore(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "NEORECALL_BACKUP_RETAIN":
			return "2"
		default:
			return ""
		}
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	_ = cfg.Paths.Ensure()

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	uid := "00000000-0000-0000-0000-000000000061"
	if _, err := db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'bakuser', 'bak@x.io', 'h', 'admin')`, uid); err != nil {
		t.Fatal(err)
	}

	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	svc := &backup.Service{
		DB: db, Cfg: func() config.Config { return cfg }, MasterKey: keyFn,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	var latest backup.Artifact
	for i := 0; i < 3; i++ {
		art, err := svc.Create(ctx)
		if err != nil {
			t.Fatal(err)
		}
		latest = art
		sealedPath := filepath.Join(cfg.Paths.Backups, art.Key)
		if !filebox.HasMagic(sealedPath, crypto.BackupMagic) {
			t.Fatalf("expected NRB1 magic on %s", sealedPath)
		}
	}

	st, err := svc.Status()
	if err != nil {
		t.Fatal(err)
	}
	items := st["items"].([]backup.Artifact)
	if len(items) != 2 {
		t.Fatalf("expected retention=2, got %d items", len(items))
	}

	// Restore to a fresh DB path and verify user row survived.
	_ = db.Close()
	restoredPath := filepath.Join(home, "restored.db")
	key, _ := keyFn()
	if err := backup.RestoreFile(key, filepath.Join(cfg.Paths.Backups, latest.Key), restoredPath); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(restoredPath); err != nil {
		t.Fatal(err)
	}
	db2, err := dbx.Open(ctx, restoredPath, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	var uname string
	if err := db2.R.QueryRowContext(ctx, `SELECT username FROM users WHERE id=?`, uid).Scan(&uname); err != nil || uname != "bakuser" {
		t.Fatalf("expected restored bakuser, got %q err=%v", uname, err)
	}
}
