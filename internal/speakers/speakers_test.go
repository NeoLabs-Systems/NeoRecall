package speakers_test

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

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/google/uuid"
)

func TestClusteringMarginAndForbidden(t *testing.T) {
	items := []speakers.ClusterItem{
		{ID: "c1", Embeddings: [][]float32{{1, 0, 0}}},
		{ID: "c2", Embeddings: [][]float32{{0.99, 0.14, 0}}},
		{ID: "c3", Embeddings: [][]float32{{0.98, 0.18, 0}}},
	}
	// Margin 0.05 should still merge since all three exceed threshold 0.70 (rivals above bar do not block).
	groups := speakers.Cluster(items, 0.70, 0.05, func(a, b string) bool {
		return (a == "c1" && b == "c3") || (a == "c3" && b == "c1")
	})
	// c1 & c3 forbidden, so max 2 groups: {c1, c2} and {c3} (or depending on pair scores, c1&c3 never in same group).
	for _, g := range groups {
		has1, has3 := false, false
		for _, m := range g.MemberIDs {
			if m == "c1" {
				has1 = true
			}
			if m == "c3" {
				has3 = true
			}
		}
		if has1 && has3 {
			t.Fatalf("forbidden pair c1 & c3 merged into group %+v", g)
		}
	}
}

func TestResolveConversationMergesAndVoiceprintSealing(t *testing.T) {
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

	authSvc := &auth.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn}
	authn := &auth.Authenticator{Service: authSvc, Log: log}
	procSvc := &processing.Service{DB: db, Cfg: cfgFn}
	jobSvc := &jobs.Service{DB: db, Cfg: cfgFn}
	spkSvc := &speakers.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Proc: procSvc, Jobs: jobSvc, Log: log}

	mux := http.NewServeMux()
	auth.NewRoutes(authSvc, authn, log).Mount(mux)
	(&speakers.Routes{Svc: spkSvc, Auth: authn, Log: log}).Mount(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Register user.
	res, err := http.Post(srv.URL+"/api/v1/auth/register", "application/json",
		strings.NewReader(`{"username":"spkuser","email":"spk@example.com","password":"very-long-password-123"}`))
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("register failed: %v", err)
	}
	var reg struct {
		User    auth.User         `json:"user"`
		Session auth.SessionToken `json:"session"`
	}
	_ = json.NewDecoder(res.Body).Decode(&reg)
	res.Body.Close()

	// Seed device, session, source, 2 chunks, 2 clusters of the SAME speaker (vector [1,0,0,0] and [0.99,0.1,0,0]), and 1 conversation.
	devID, sessID, srcID, convID := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	ch1, ch2 := uuid.NewString(), uuid.NewString()
	cl1, cl2 := uuid.NewString(), uuid.NewString()

	mustExec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.W.Exec(q, args...); err != nil {
			t.Fatalf("exec %q: %v", q, err)
		}
	}
	mustExec(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dev-spk-1234', 'Mac', 'macos', 'desktop')`, devID, reg.User.ID)
	mustExec(`INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, initial_clock_offset_ms, consent_attested_at, status)
		VALUES (?, ?, ?, 'sess-spk-1234', '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z', 'UTC', 0, '2026-01-01T10:00:00Z', 'ended')`, sessID, reg.User.ID, devID)
	mustExec(`INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format) VALUES (?, ?, 'src-spk-1234', 'microphone', 'mono', 16000, 'pcm_s16le')`, srcID, sessID)
	mustExec(`INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, state)
		VALUES (?, ?, ?, ?, 0, 'k1', '`+strings.Repeat("a", 64)+`', 100, 'wav', 'pcm_s16le', 'mono', '2026-01-01T10:00:00Z', 0, 10000, 'transcribed')`, ch1, reg.User.ID, sessID, srcID)
	mustExec(`INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, state)
		VALUES (?, ?, ?, ?, 1, 'k2', '`+strings.Repeat("b", 64)+`', 100, 'wav', 'pcm_s16le', 'mono', '2026-01-01T10:00:10Z', 10000, 10000, 'transcribed')`, ch2, reg.User.ID, sessID, srcID)
	mustExec(`INSERT INTO conversations (id, user_id, state, started_at, ended_at, boundary_method, boundary_version) VALUES (?, ?, 'closed', '2026-01-01T10:00:00Z', '2026-01-01T10:00:20Z', 'gap', 'v1')`, convID, reg.User.ID)

	vec1 := transcription.VectorToBytes([]float32{1, 0, 0, 0})
	vec2 := transcription.VectorToBytes([]float32{0.99, 0.1, 0, 0})
	mustExec(`INSERT INTO speaker_clusters (id, user_id, session_id, local_ordinal, centroid_embedding, embedding_model, embedding_dimensions, sample_count) VALUES (?, ?, ?, 1, ?, ?, 4, 1)`, cl1, reg.User.ID, sessID, vec1, speakers.ModelName)
	mustExec(`INSERT INTO speaker_clusters (id, user_id, session_id, local_ordinal, centroid_embedding, embedding_model, embedding_dimensions, sample_count) VALUES (?, ?, ?, 2, ?, ?, 4, 1)`, cl2, reg.User.ID, sessID, vec2, speakers.ModelName)

	t1, t2 := uuid.NewString(), uuid.NewString()
	mustExec(`INSERT INTO speaker_turns (id, user_id, chunk_id, cluster_id, start_ms, end_ms, embedding, quality) VALUES (?, ?, ?, ?, 0, 9000, ?, 1.0)`, t1, reg.User.ID, ch1, cl1, vec1)
	mustExec(`INSERT INTO speaker_turns (id, user_id, chunk_id, cluster_id, start_ms, end_ms, embedding, quality) VALUES (?, ?, ?, ?, 0, 9000, ?, 1.0)`, t2, reg.User.ID, ch2, cl2, vec2)

	mustExec(`INSERT INTO transcript_segments (public_id, user_id, chunk_id, conversation_id, speaker_cluster_id, source_component, chunk_start_ms, chunk_end_ms, started_at, ended_at, text)
		VALUES (?, ?, ?, ?, ?, 'combined', 0, 9000, '2026-01-01T10:00:00Z', '2026-01-01T10:00:09Z', 'First part')`, uuid.NewString(), reg.User.ID, ch1, convID, cl1)
	mustExec(`INSERT INTO transcript_segments (public_id, user_id, chunk_id, conversation_id, speaker_cluster_id, source_component, chunk_start_ms, chunk_end_ms, started_at, ended_at, text)
		VALUES (?, ?, ?, ?, ?, 'combined', 0, 9000, '2026-01-01T10:00:10Z', '2026-01-01T10:00:19Z', 'Second part')`, uuid.NewString(), reg.User.ID, ch2, convID, cl2)

	outcome, err := spkSvc.ResolveConversation(ctx, reg.User.ID, convID)
	if err != nil {
		t.Fatalf("ResolveConversation failed: %v", err)
	}
	if outcome.MergedClusters != 1 || outcome.AssignedTurns != 2 {
		t.Fatalf("expected 1 merged cluster & 2 assigned turns, got %+v", outcome)
	}

	// Verify voiceprint centroid is AES-GCM sealed at rest!
	var vpID string
	var sealed []byte
	if err := db.R.QueryRow(`SELECT id, centroid_embedding FROM voiceprints WHERE user_id=?`, reg.User.ID).Scan(&vpID, &sealed); err != nil {
		t.Fatal(err)
	}
	key, _ := keyFn()
	if !crypto.IsSealedBuffer(key, sealed) {
		t.Fatalf("expected voiceprint centroid_embedding to be sealed at rest")
	}
	if bytes.Equal(sealed, vec1) {
		t.Fatalf("centroid stored in plaintext")
	}

	// Update voiceprint display name via PATCH /api/v1/speakers/{id}.
	req, _ := http.NewRequest("PATCH", srv.URL+"/api/v1/speakers/"+vpID, strings.NewReader(`{"displayName":"Alice"}`))
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	req.Header.Set("Content-Type", "application/json")
	pRes, err := http.DefaultClient.Do(req)
	if err != nil || pRes.StatusCode != 200 {
		t.Fatalf("PATCH speaker failed: %v %v", err, pRes)
	}
	pRes.Body.Close()

	// Seed preview meeting SpeakerDisplayMinPreviewMs threshold so GET /api/v1/speakers lists Alice.
	mustExec(`INSERT INTO speaker_previews (voiceprint_id, user_id, audio, content_type, duration_ms, quality) VALUES (?, ?, ?, 'audio/wav', 10000, 1.0)`, vpID, reg.User.ID, []byte("RIFFxxxxWAVE"))
	req, _ = http.NewRequest("GET", srv.URL+"/api/v1/speakers", nil)
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	gRes, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer gRes.Body.Close()
	var listOut struct {
		Speakers []speakers.ListedSpeaker `json:"speakers"`
	}
	_ = json.NewDecoder(gRes.Body).Decode(&listOut)
	if len(listOut.Speakers) != 1 || listOut.Speakers[0].DisplayName == nil || *listOut.Speakers[0].DisplayName != "Alice" {
		t.Fatalf("expected Alice in speakers list, got %+v", listOut)
	}
}
