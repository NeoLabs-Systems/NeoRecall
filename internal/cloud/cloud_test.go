package cloud_test

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
)

func TestNormalizeInstanceURLAndNeoCloudBackup(t *testing.T) {
	if _, err := cloud.NormalizeInstanceURL("https://user:pass@cloud.example.com", "NeoCloud"); err == nil {
		t.Fatal("must reject credentials in URL")
	}
	if _, err := cloud.NormalizeInstanceURL("http://169.254.169.254", "Nextcloud"); err == nil {
		t.Fatal("must reject link-local metadata IP")
	}
	if _, err := cloud.NormalizeInstanceURL("http://cloud.example.com", "Nextcloud"); err == nil {
		t.Fatal("must reject plaintext HTTP on non-private host")
	}
	u, err := cloud.NormalizeInstanceURL("http://127.0.0.1:9000/", "NeoCloud")
	if err != nil || u != "http://127.0.0.1:9000" {
		t.Fatalf("unexpected normalized loopback URL: %q err=%v", u, err)
	}

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

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	uid := "00000000-0000-0000-0000-000000000071"
	_, _ = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'cloudu', 'cl@x.io', 'h', 'user')`, uid)

	var mu sync.Mutex
	var uploadedZip []byte
	mockNeoCloud := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/version":
			_, _ = w.Write([]byte(`{"product":"neocloud"}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/devices/authorize":
			_, _ = w.Write([]byte(`{"deviceCode":"dc-1","userCode":"UC-123","expiresIn":600,"interval":1}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/devices/token":
			_, _ = w.Write([]byte(`{"token":"nc-tok-1","user":{"username":"neo"},"device":{"id":"nc-dev-1"}}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/devices/me":
			_, _ = w.Write([]byte(`{"user":{"username":"neo"},"quota":{"used":120,"limit":1024}}`))
		case r.Method == http.MethodPost && r.URL.Path == "/api/folders":
			_, _ = w.Write([]byte(`{"id":"fld-1"}`))
		case r.Method == http.MethodPut && r.URL.Path == "/api/upload":
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			uploadedZip = b
			mu.Unlock()
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"id":"node-1"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockNeoCloud.Close()

	cfgFn := func() config.Config { return cfg }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := &cloud.Service{
		DB: db, Cfg: cfgFn, MasterKey: keyFn, Jobs: &jobs.Service{DB: db},
		Settings: &settings.Service{DB: db, Cfg: cfgFn}, HTTP: mockNeoCloud.Client(), Log: log,
	}

	authSvc := &auth.Service{DB: db, Cfg: cfgFn}
	key, _ := authSvc.CreateAPIKey(ctx, uid, "cl-key", []string{"settings:read", "settings:write"}, nil)
	mux := http.NewServeMux()
	(&cloud.Routes{Svc: svc, Auth: &auth.Authenticator{Service: authSvc, Log: log}, Log: log}).Mount(mux)

	// Start & poll NeoCloud login
	startReq := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/neocloud/login", strings.NewReader(`{"url":"`+mockNeoCloud.URL+`"}`))
	startReq.Header.Set("Authorization", "Bearer "+key.Token)
	startRec := httptest.NewRecorder()
	mux.ServeHTTP(startRec, startReq)
	if startRec.Code != http.StatusOK || !strings.Contains(startRec.Body.String(), "UC-123") {
		t.Fatalf("neocloud start failed: %d %s", startRec.Code, startRec.Body.String())
	}

	pollReq := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/neocloud/poll", nil)
	pollReq.Header.Set("Authorization", "Bearer "+key.Token)
	pollRec := httptest.NewRecorder()
	mux.ServeHTTP(pollRec, pollReq)
	if pollRec.Code != http.StatusOK || !strings.Contains(pollRec.Body.String(), `"connected":true`) {
		t.Fatalf("neocloud poll failed: %d %s", pollRec.Code, pollRec.Body.String())
	}

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/cloud", nil)
	getReq.Header.Set("Authorization", "Bearer "+key.Token)
	getRec := httptest.NewRecorder()
	mux.ServeHTTP(getRec, getReq)
	if getRec.Code != 200 || !strings.Contains(getRec.Body.String(), `"cloud":{"`) {
		t.Fatalf("cloud envelope: %d %s", getRec.Code, getRec.Body.String())
	}
	legacyReq := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/backup", nil)
	legacyReq.Header.Set("Authorization", "Bearer "+key.Token)
	legacyRec := httptest.NewRecorder()
	mux.ServeHTTP(legacyRec, legacyReq)
	if legacyRec.Code != 200 || !strings.Contains(legacyRec.Body.String(), `"queued":true`) {
		t.Fatalf("legacy cloud backup: %d %s", legacyRec.Code, legacyRec.Body.String())
	}
	// Backup now -> exports zip, seals locally, unseals to plaintext for upload, verifies ZIP is readable.
	bakReq := httptest.NewRequest(http.MethodPost, "/api/v1/cloud/backup-now", nil)
	bakReq.Header.Set("Authorization", "Bearer "+key.Token)
	bakRec := httptest.NewRecorder()
	mux.ServeHTTP(bakRec, bakReq)
	if bakRec.Code != http.StatusOK {
		t.Fatalf("backup-now failed: %d %s", bakRec.Code, bakRec.Body.String())
	}

	mu.Lock()
	zb := uploadedZip
	mu.Unlock()
	zr, err := zip.NewReader(bytes.NewReader(zb), int64(len(zb)))
	if err != nil || len(zr.File) != 2 {
		t.Fatalf("expected valid 2-entry backup zip uploaded plaintext, err=%v len=%d", err, len(zb))
	}
}
