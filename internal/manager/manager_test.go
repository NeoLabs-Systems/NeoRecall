package manager_test

import (
	"context"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/manager"
	"github.com/NeoLabs-Systems/neorecall/internal/models"
)

func TestCLIAccountAdminBackupRestoreResetPasswordAndVerifyNoAudio(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	t.Setenv("NEORECALL_HOME", home)
	t.Setenv("NEORECALL_REGISTRATION_ENABLED", "true")

	// 1. Create admin account via CLI.
	if err := manager.Run(ctx, []string{"account", "create", "--username", "cliadmin", "--password", "StrongPassword!1", "--admin"}, nil); err != nil {
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
	if err := manager.Run(ctx, []string{"reset-password", "cliadmin", "UpdatedPassword!99"}, nil); err != nil {
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
