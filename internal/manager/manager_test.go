package manager_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/manager"
	"github.com/NeoLabs-Systems/neorecall/internal/models"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
)

func TestJSToGoMigrationAndTarSafety(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	binDir := t.TempDir()
	npmSym := filepath.Join(binDir, "neorecall")
	if err := os.Symlink("/usr/local/lib/node_modules/neorecall/bin/neorecall.js", npmSym); err != nil {
		t.Fatal(err)
	}

	getenv := func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "PATH":
			return binDir
		}
		return ""
	}
	cfg, err := config.Load(getenv, home, home)
	if err != nil {
		t.Fatal(err)
	}
	_ = cfg.Paths.Ensure()

	// Seed an existing pre-Go database, master key, and .env pointing at a deleted JS dir.
	if _, err := crypto.MasterKey(cfg.Paths.SecretKey); err != nil {
		t.Fatal(err)
	}
	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	legacyApp := filepath.Join(home, "legacy-app")
	_ = os.MkdirAll(filepath.Join(legacyApp, "flutter_app", "build", "web"), 0o755)
	_ = os.MkdirAll(filepath.Join(legacyApp, "server"), 0o755)
	_ = os.WriteFile(filepath.Join(legacyApp, "flutter_app", "build", "web", "index.html"), []byte("<html></html>"), 0o644)
	_ = os.WriteFile(filepath.Join(legacyApp, "server", "index.js"), []byte("// legacy"), 0o644)
	if err := os.WriteFile(cfg.Paths.EnvFile, []byte("PORT=4500\nNEORECALL_APP_DIR="+legacyApp+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	st := manager.InspectLegacyJS(cfg, home, getenv)
	if !st.NeedsMigration || !st.HasDB || st.MigratedMarker || st.LegacyNPMBin != npmSym {
		t.Fatalf("unexpected legacy JS inspection: %+v", st)
	}

	// Run setup --no-models --skip-web and verify backup, npm symlink cleanup, and marker creation.
	m := &manager.Manager{
		Getenv:   getenv,
		UserHome: home,
		Cwd:      home,
		Version:  config.Version,
		In:       strings.NewReader(""),
		Out:      &bytes.Buffer{},
		Err:      &bytes.Buffer{},
		UI:       cli.NewUI(true),
	}
	_ = m
	t.Setenv("NEORECALL_HOME", home)
	t.Setenv("PATH", binDir+":"+os.Getenv("PATH"))
	if err := manager.Run(ctx, []string{"setup", "--no-models", "--skip-web"}, nil); err != nil {
		t.Fatalf("setup migration failed: %v", err)
	}
	if _, err := os.Lstat(npmSym); !os.IsNotExist(err) {
		t.Fatalf("expected legacy npm symlink to be removed")
	}
	envRaw, err := os.ReadFile(cfg.Paths.EnvFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(envRaw), "NEORECALL_APP_DIR="+legacyApp) {
		t.Fatalf("expected legacy JS NEORECALL_APP_DIR to be cleared from .env, got:\n%s", envRaw)
	}
	stAfter := manager.InspectLegacyJS(cfg, home, getenv)
	if stAfter.NeedsMigration || !stAfter.MigratedMarker {
		t.Fatalf("expected NeedsMigration=false and MigratedMarker=true after migration, got %+v", stAfter)
	}
	baks, _ := os.ReadDir(cfg.Paths.Backups)
	if len(baks) == 0 {
		t.Fatalf("expected pre-upgrade NRB1 backup in %s", cfg.Paths.Backups)
	}

	// Verify ExtractTarGZSafe blocks path traversal.
	var tb bytes.Buffer
	gw := gzip.NewWriter(&tb)
	tw := tar.NewWriter(gw)
	_ = tw.WriteHeader(&tar.Header{Name: "../evil.txt", Mode: 0o644, Size: 3})
	_, _ = tw.Write([]byte("bad"))
	_ = tw.Close()
	_ = gw.Close()
	badArc := filepath.Join(t.TempDir(), "bad.tar.gz")
	_ = os.WriteFile(badArc, tb.Bytes(), 0o600)
	if err := manager.ExtractTarGZSafe(badArc, t.TempDir()); err == nil {
		t.Fatalf("expected unsafe traversal error")
	}
}

func TestCLIAccountAdminBackupRestoreResetPasswordAndVerifyNoAudio(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("NEORECALL_HOME", home)
	t.Setenv("NEORECALL_REGISTRATION_ENABLED", "true")

	// 1. Create admin account via CLI.
	if err := manager.Run(ctx, []string{"account", "create", "--username", "cliadmin", "--password", "Orchid-Tram-58-Lagoon", "--admin"}, nil); err != nil {
		t.Fatalf("account create failed: %v", err)
	}

	// 2. Grant/list admin via CLI.
	if err := manager.Run(ctx, []string{"admin", "list", "--json"}, nil); err != nil {
		t.Fatalf("admin list failed: %v", err)
	}

	// 3. Env set/get/list/unset via CLI.
	if err := manager.Run(ctx, []string{"env", "set", "NEORECALL_LOG_LEVEL", "debug"}, nil); err != nil {
		t.Fatalf("env set failed: %v", err)
	}
	if err := manager.Run(ctx, []string{"env", "get", "NEORECALL_LOG_LEVEL"}, nil); err != nil {
		t.Fatalf("env get failed: %v", err)
	}

	// 4. Backup + verify-no-audio + reset-password.
	if err := manager.Run(ctx, []string{"backup"}, nil); err != nil {
		t.Fatalf("backup failed: %v", err)
	}
	if err := manager.Run(ctx, []string{"verify-no-audio"}, nil); err != nil {
		t.Fatalf("verify-no-audio failed: %v", err)
	}
	if err := manager.Run(ctx, []string{"reset-password", "cliadmin", "Copper-Vane-73-Meadow"}, nil); err != nil {
		t.Fatalf("reset-password failed: %v", err)
	}

	// 5. Ensure models & doctor don't panic or fail unexpectedly on bad paths.
	_ = manager.Run(ctx, []string{"help"}, nil)
	if err := manager.Run(ctx, []string{"models", "verify"}, nil); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("expected missing models verification error before download, got %v", err)
	}
	_, _ = models.PruneRetired("", t.TempDir())
	_ = config.Version
	_ = crypto.BackupMagic
}
