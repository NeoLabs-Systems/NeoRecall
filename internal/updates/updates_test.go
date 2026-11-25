package updates_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
)

func TestStandaloneSelfUpdateSemverAndChannelPersistence(t *testing.T) {
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	_ = cfg.Paths.Ensure()

	// Out-of-semver-order GitHub releases response + non-semver tag (like desk-latest).
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
			{"tag_name":"v0.1.4-beta.9","draft":false,"prerelease":true},
			{"tag_name":"desk-latest","draft":false,"prerelease":true},
			{"tag_name":"v0.1.4-beta.12","draft":false,"prerelease":true},
			{"tag_name":"v0.1.3","draft":false,"prerelease":false}
		]`))
	}))
	defer srv.Close()

	t.Setenv("NEORECALL_RELEASE_CHANNEL", "")
	svc := &updates.Service{
		Cfg:            func() config.Config { return cfg },
		AppDir:         home, // no .git directory (standalone binary install)
		CurrentVersion: "0.1.4-beta.11",
		HTTP:           srv.Client(),
		ReleaseAPIBase: srv.URL,
	}

	st := svc.Status()
	br, _ := st["blockedReason"].(*string)
	if st["selfUpdate"] != true || br != nil {
		t.Fatalf("standalone install must allow self-update, got %+v", st)
	}

	if _, err := svc.SetChannel("beta"); err != nil {
		t.Fatalf("SetChannel beta failed: %v", err)
	}
	envBytes, err := os.ReadFile(cfg.Paths.EnvFile)
	if err != nil || !strings.Contains(string(envBytes), "NEORECALL_RELEASE_CHANNEL=beta") {
		t.Fatalf("expected channel persisted in .env, got %q err=%v", string(envBytes), err)
	}

	chk := svc.Check()
	avail, _ := chk["available"].(map[string]any)
	if avail == nil || avail["version"] != "0.1.4-beta.12" {
		t.Fatalf("expected highest semver beta update 0.1.4-beta.12, got %+v", chk)
	}
}
