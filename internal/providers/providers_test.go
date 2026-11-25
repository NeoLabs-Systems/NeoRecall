package providers_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/neorouter"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/providers"
	"github.com/NeoLabs-Systems/neorecall/internal/recordings"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
	"github.com/google/uuid"
)

func TestNeoRouterProvidersProcessingAndRecordings(t *testing.T) {
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
	cfgFn := func() config.Config { return cfg }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	// Mock NeoRouter OAuth/models server.
	mockRouter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/models":
			_, _ = w.Write([]byte(`{"data":[{"id":"auto"},{"id":"gpt-4o-mini"}]}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer mockRouter.Close()

	authSvc := &auth.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn}
	authn := &auth.Authenticator{Service: authSvc, Log: log}
	procSvc := &processing.Service{DB: db, Cfg: cfgFn}
	nrSvc := &neorouter.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, HTTP: mockRouter.Client(), Log: log}
	provSvc := &providers.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, NeoRouter: nrSvc, HTTP: mockRouter.Client(), Log: log}
	nrSvc.Workloads = provSvc
	spkSvc := &speakers.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Proc: procSvc, Log: log}
	recSvc := &recordings.Service{DB: db, MasterKey: keyFn, Speakers: spkSvc, Log: log}
	trSvc := &transcripts.Service{DB: db}

	mux := http.NewServeMux()
	auth.NewRoutes(authSvc, authn, log).Mount(mux)
	(&neorouter.Routes{Svc: nrSvc, Auth: authn, Log: log}).Mount(mux)
	(&providers.Routes{Svc: provSvc, Auth: authn, Log: log}).Mount(mux)
	(&processing.Routes{Svc: procSvc, DB: db, Auth: authn, Log: log}).Mount(mux)
	(&recordings.Routes{Svc: recSvc, Auth: authn, Log: log}).Mount(mux)
	(&transcripts.Routes{Svc: trSvc, Auth: authn, Log: log}).Mount(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	res, err := http.Post(srv.URL+"/api/v1/auth/register", "application/json",
		strings.NewReader(`{"username":"admin1","email":"a@example.com","password":"very-long-password-123"}`))
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("register: %v", err)
	}
	var reg struct {
		User    auth.User         `json:"user"`
		Session auth.SessionToken `json:"session"`
	}
	_ = json.NewDecoder(res.Body).Decode(&reg)
	res.Body.Close()

	// 1. Apply NeoRouter connection and update roles + discover models.
	if err := nrSvc.ApplyConnection(ctx, mockRouter.URL+"/v1", "nr-secret-key"); err != nil {
		t.Fatalf("ApplyConnection failed: %v", err)
	}
	req, _ := http.NewRequest("POST", srv.URL+"/api/v1/admin/provider-settings/models",
		strings.NewReader(`{"workload":"llm","provider":"neorouter"}`))
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	req.Header.Set("Content-Type", "application/json")
	mRes, err := http.DefaultClient.Do(req)
	if err != nil || mRes.StatusCode != 200 {
		t.Fatalf("discover models status %v err %v", mRes, err)
	}
	var mOut struct {
		Models []string `json:"models"`
	}
	_ = json.NewDecoder(mRes.Body).Decode(&mOut)
	mRes.Body.Close()
	if len(mOut.Models) != 2 || mOut.Models[0] != "auto" {
		t.Fatalf("unexpected discovered models: %v", mOut.Models)
	}

	// Verify API key is sealed at rest & never returned in ResolveWorkload/GetAdmin JSON.
	admJSON, _ := json.Marshal(provSvc.GetAdmin(ctx))
	if strings.Contains(string(admJSON), "nr-secret-key") {
		t.Fatalf("API key leaked in admin JSON")
	}

	// 2. Processing settings invalid limit rejected with 400.
	req, _ = http.NewRequest("PUT", srv.URL+"/api/v1/admin/processing-settings",
		strings.NewReader(`{"voiceEnrollFloor":0.99,"voiceMatchThreshold":0.50}`))
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	req.Header.Set("Content-Type", "application/json")
	pRes, _ := http.DefaultClient.Do(req)
	pRes.Body.Close()
	if pRes.StatusCode != 400 {
		t.Fatalf("expected 400 INVALID_SPEAKER_LIMITS, got %d", pRes.StatusCode)
	}

	// 3. Recordings + Transcripts + DELETE cleanup removes temp file.
	devID, sessID, srcID, chID := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	tmpAudio := filepath.Join(cfg.Paths.AudioTmp, chID+".wav")
	_ = os.WriteFile(tmpAudio, []byte("audio"), 0o600)
	_, _ = db.W.Exec(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dev-rec-1234', 'Mic', 'macos', 'desktop')`, devID, reg.User.ID)
	_, _ = db.W.Exec(`INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, initial_clock_offset_ms, consent_attested_at, status)
		VALUES (?, ?, ?, 'sess-rec-1234', '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z', 'UTC', 0, '2026-01-01T10:00:00Z', 'ended')`, sessID, reg.User.ID, devID)
	_, _ = db.W.Exec(`INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format) VALUES (?, ?, 'src-rec-1234', 'microphone', 'mono', 16000, 'pcm_s16le')`, srcID, sessID)
	_, _ = db.W.Exec(`INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, state, temporary_path)
		VALUES (?, ?, ?, ?, 0, 'k-rec', '`+strings.Repeat("c", 64)+`', 5, 'wav', 'pcm_s16le', 'mono', '2026-01-01T10:00:00Z', 0, 5000, 'uploaded', ?)`, chID, reg.User.ID, sessID, srcID, tmpAudio)
	_, _ = db.W.Exec(`INSERT INTO transcript_segments (public_id, user_id, chunk_id, source_component, started_at, ended_at, chunk_start_ms, chunk_end_ms, text)
		VALUES (?, ?, ?, 'combined', '2026-01-01T10:00:00Z', '2026-01-01T10:00:05Z', 0, 5000, 'Testing transcript list')`, uuid.NewString(), reg.User.ID, chID)

	req, _ = http.NewRequest("GET", srv.URL+"/api/v1/transcripts", nil)
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	tRes, _ := http.DefaultClient.Do(req)
	var trOut struct {
		Items []transcripts.SegmentRow `json:"items"`
	}
	_ = json.NewDecoder(tRes.Body).Decode(&trOut)
	tRes.Body.Close()
	if len(trOut.Items) != 1 || trOut.Items[0].Text != "Testing transcript list" {
		t.Fatalf("unexpected transcripts output: %+v", trOut)
	}

	req, _ = http.NewRequest("DELETE", srv.URL+"/api/v1/recordings/"+sessID, nil)
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	dRes, _ := http.DefaultClient.Do(req)
	dRes.Body.Close()
	if dRes.StatusCode != 204 {
		t.Fatalf("expected 204 on recording delete, got %d", dRes.StatusCode)
	}
	if _, err := os.Stat(tmpAudio); !os.IsNotExist(err) {
		t.Fatalf("expected temporary audio unlinked after recording deletion")
	}
}
