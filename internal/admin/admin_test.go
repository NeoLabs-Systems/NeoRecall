package admin_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/admin"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/sources"
	"github.com/NeoLabs-Systems/neorecall/internal/status"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

func TestAdminSourcesStatusAndUpdates(t *testing.T) {
	ctx := context.Background()
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

	db, err := schema.Open(ctx, cfg.Paths, "")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}

	cfgFn := func() config.Config { return cfg }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	authSvc := &auth.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn}
	authn := &auth.Authenticator{Service: authSvc, Log: log}

	regUser, sessTok, err := authSvc.Register(ctx, "boss", nil, "Orchid-Tram-58-Lagoon", auth.RequestContext{IPAddress: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if regUser.Role != "admin" {
		t.Fatalf("expected first user to be admin, got %s", regUser.Role)
	}

	admSvc := &admin.Service{
		DB:         db,
		Cfg:        cfgFn,
		Jobs:       &jobs.Service{DB: db},
		Embeddings: &embeddings.Service{DB: db, Cfg: cfgFn, Jobs: &jobs.Service{DB: db}},
		Usage:      &usage.Service{DB: db, Cfg: cfgFn},
		Backups:    &backup.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Log: log},
		Updates:    &updates.Service{Cfg: cfgFn, CurrentVersion: "1.0.0"},
		Log:        log,
	}
	stSvc := &status.Service{
		DB: db, Cfg: cfgFn, Usage: admSvc.Usage,
		TranscriptionReadyFn: func(context.Context) bool { return true },
		AIReadyFn:            func(context.Context) bool { return false },
		Log:                  log,
	}

	mux := http.NewServeMux()
	(&admin.Routes{Svc: admSvc, Auth: authn, Log: log}).Mount(mux)
	(&status.Routes{Svc: stSvc, Auth: authn, Log: log}).Mount(mux)
	(&sources.Routes{DB: db, Auth: authn, Log: log}).Mount(mux)

	get := func(path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+sessTok.Token)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}

	if rec := get("/api/v1/admin/stats"); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"users":1`) {
		t.Fatalf("admin stats failed: %d %s", rec.Code, rec.Body.String())
	}

	for path, key := range map[string]string{"/api/v1/admin/users": "users", "/api/v1/admin/jobs": "jobs", "/api/v1/admin/ai-requests": "requests", "/api/v1/admin/audit": "entries", "/api/v1/admin/config/usage-limits": "limits", "/api/v1/admin/users/" + regUser.ID + "/usage-limits": "userId"} {
		rec := get(path)
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); rec.Code != 200 || err != nil || body[key] == nil {
			t.Fatalf("%s contract: %d %s %v", path, rec.Code, rec.Body.String(), err)
		}
	}
	if rec := get("/api/v1/admin/update"); rec.Code != 200 {
		t.Fatalf("admin update failed: %d %s", rec.Code, rec.Body.String())
	}
	if rec := get("/api/v1/sources/types"); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"types":[]`) {
		t.Fatalf("sources types failed: %d %s", rec.Code, rec.Body.String())
	}
	if rec := get("/api/v1/processing-status"); rec.Code != 200 || !strings.Contains(rec.Body.String(), "LANGUAGE_MODEL_NOT_CONFIGURED") {
		t.Fatalf("processing status failed: %d %s", rec.Code, rec.Body.String())
	}

	// Create backup via admin route and list it.
	bakReq := httptest.NewRequest(http.MethodPost, "/api/v1/admin/backups", bytes.NewReader(nil))
	bakReq.Header.Set("Authorization", "Bearer "+sessTok.Token)
	bakRec := httptest.NewRecorder()
	mux.ServeHTTP(bakRec, bakReq)
	if bakRec.Code != http.StatusOK {
		t.Fatalf("POST /admin/backups failed: %d %s", bakRec.Code, bakRec.Body.String())
	}
	var art backup.Artifact
	_ = json.Unmarshal(bakRec.Body.Bytes(), &art)
	if dlRec := get("/api/v1/admin/backups/" + art.Key + "/download"); dlRec.Code != 200 || !bytes.HasPrefix(dlRec.Body.Bytes(), []byte("NRB1")) {
		t.Fatalf("download backup failed: %d len=%d", dlRec.Code, dlRec.Body.Len())
	}
}
