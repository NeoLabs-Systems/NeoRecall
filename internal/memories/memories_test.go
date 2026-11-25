package memories_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

type stubMemAI struct{}

func (s *stubMemAI) Ready(_ context.Context) bool { return true }
func (s *stubMemAI) Consolidate(_ context.Context, _ string, in ai.ConsolidationInput) (ai.ConsolidationResult, error) {
	segID := in.Conversations[0].Segments[0].ID
	due := "2026-04-05T12:00:00.000Z"
	status := "open"
	return ai.ConsolidationResult{
		RequestID: "",
		Windows:   1,
		Value: ai.ConsolidationOutput{
			ConversationSections: []ai.ConversationSection{{
				TitleEn: "Product Sync", SummaryEn: "Agreed on beta milestones.", MemoryWorthy: true,
				Topics: []string{"beta"}, SourceSegmentIDs: []string{segID},
			}},
			Entities: []ai.ConsolidationEntity{{
				Ref: "e1", Kind: "person", CanonicalNameEn: "Bob",
			}},
			Memories: []ai.ConsolidationMemory{{
				Type: "meeting", TitleEn: "Beta Sync", SummaryEn: "Bob committed to shipping Beta on Friday.",
				Emoji: "🤝", Importance: 8, SourceSegmentIDs: []string{segID}, Topics: []string{"beta"},
				Entities: []ai.EntityReference{{Ref: "e1", Role: "participant"}},
				MiniMemories: []ai.ConsolidationMiniMemory{{
					Kind: "task", TextEn: "Ship Beta", Importance: 7, Confidence: 0.9,
					DueAtISO: &due, Status: &status, SourceSegmentIDs: []string{segID},
				}},
			}},
		},
	}, nil
}
func (s *stubMemAI) WriteDailySummary(_ context.Context, _ string, _ []ai.ConversationSection, _ *ai.PreviousDailySummary, _ string) (*ai.DailySummaryOutput, error) {
	return &ai.DailySummaryOutput{SummaryEn: "Daily recap for 2026-04-01"}, nil
}
func (s *stubMemAI) RewriteMergedMemory(_ context.Context, _ string, _ []ai.MemoryMergeInput) (ai.MemoryMergeOutput, string, error) {
	return ai.MemoryMergeOutput{Type: "meeting", TitleEn: "Merged Sync", SummaryEn: "Combined notes.", Emoji: "🤝"}, "req-m-1", nil
}
func (s *stubMemAI) JudgeDuplicateMemories(_ context.Context, _ string, _, _ ai.MemoryMergeInput, _ int, _ bool) (ai.MemoryDedupeOutput, string, error) {
	return ai.MemoryDedupeOutput{Reasoning: "same", SameOccasion: false}, "req-d-1", nil
}
func (s *stubMemAI) RewriteMemoryWithContext(_ context.Context, _ string, mem ai.RewriteContextMemory, _ []ai.RewriteContextSegment, _ []ai.RewriteContextItem) (ai.RewriteContextOutput, string, error) {
	return ai.RewriteContextOutput{Type: mem.Type, TitleEn: mem.TitleEn, SummaryEn: mem.SummaryEn + " (with note)", Emoji: "📝", Importance: mem.Importance}, "req-rw-1", nil
}

func TestConsolidationMemoriesAndRoutes(t *testing.T) {
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

	uid := "00000000-0000-0000-0000-000000000051"
	devID := "00000000-0000-0000-0000-000000000052"
	sessID := "00000000-0000-0000-0000-000000000053"
	srcID := "00000000-0000-0000-0000-000000000054"
	chkID := "00000000-0000-0000-0000-000000000055"
	convID := "00000000-0000-0000-0000-000000000056"
	segPub := "00000000-0000-0000-0000-000000000057"

	mustExec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.W.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("exec %q: %v", q, err)
		}
	}
	mustExec(`INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'memu', 'm@x.io', 'h', 'user')`, uid)
	mustExec(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dev-cu', 'D', 'ios', 'mobile')`, devID, uid)
	mustExec(`INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
		VALUES (?, ?, ?, 'cu', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'ended')`, sessID, uid, devID)
	mustExec(`INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format)
		VALUES (?, ?, 'src-cu', 'microphone', 'mono', 16000, 'pcm_s16le')`, srcID, sessID)
	mustExec(`INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, state)
		VALUES (?, ?, ?, ?, 0, 'ik0', '0000000000000000000000000000000000000000000000000000000000000000', 100, 'wav', 'pcm', 'mono', '2026-04-01T10:00:00.000Z', 0, 300000, 'transcribed')`, chkID, uid, sessID, srcID)
	mustExec(`INSERT INTO conversations (id, user_id, started_at, ended_at, state, boundary_method, boundary_version)
		VALUES (?, ?, '2026-04-01T10:00:00.000Z', '2026-04-01T10:05:00.000Z', 'closed', 'time-gap', '1')`, convID, uid)
	mustExec(`INSERT INTO transcript_segments (public_id, user_id, chunk_id, conversation_id, source_component, started_at, ended_at, chunk_start_ms, chunk_end_ms, text)
		VALUES (?, ?, ?, ?, 'stt', '2026-04-01T10:00:00.000Z', '2026-04-01T10:05:00.000Z', 0, 300000, 'Bob committed to shipping the beta milestones cleanly before Friday. Let us make sure every engineering owner checks their integration tests, release notes, and rollout checklist carefully before the afternoon freeze window closes.')`,
		segPub, uid, chkID, convID)

	cfgFn := func() config.Config { return cfg }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	memSvc := &memories.Service{DB: db, Cfg: cfgFn, Jobs: &jobs.Service{DB: db}, AI: &stubMemAI{}, Log: log}
	consSvc := &memories.ConsolidationService{
		Memories: memSvc,
		Settings: &settings.Service{DB: db, Cfg: cfgFn},
		Usage:    &usage.Service{DB: db},
	}

	queued, runID, err := consSvc.Request(ctx, uid, true)
	if err != nil || !queued || runID == "" {
		t.Fatalf("Request failed: queued=%v runID=%s err=%v", queued, runID, err)
	}
	if err := consSvc.Execute(ctx, uid, runID, []string{convID}); err != nil {
		t.Fatalf("Execute failed: %v", err)
	}

	mems, err := memSvc.List(ctx, uid, memories.ListFilter{})
	if err != nil || len(mems) != 1 || mems[0].TitleEn != "Beta Sync" {
		t.Fatalf("expected 1 consolidated memory, got %+v err=%v", mems, err)
	}
	ds, err := memories.GetDailySummary(ctx, db, uid, "2026-04-01")
	if err != nil || ds.SummaryEn != "Daily recap for 2026-04-01" {
		t.Fatalf("expected daily summary, got %+v err=%v", ds, err)
	}

	// Test HTTP routes: PATCH memory, GET mini-memories, PATCH mini-memory.
	authSvc := &auth.Service{DB: db, Cfg: cfgFn}
	key, err := authSvc.CreateAPIKey(ctx, uid, "m-key", []string{"memories:read", "memories:write"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	(&memories.Routes{Svc: memSvc, Consolidations: consSvc, Auth: &auth.Authenticator{Service: authSvc, Log: log}, Log: log}).Mount(mux)

	patchReq := httptest.NewRequest(http.MethodPatch, "/api/v1/memories/"+mems[0].PublicID, bytes.NewBufferString(`{"pinned":true}`))
	patchReq.Header.Set("Authorization", "Bearer "+key.Token)
	patchRec := httptest.NewRecorder()
	mux.ServeHTTP(patchRec, patchReq)
	if patchRec.Code != http.StatusOK {
		t.Fatalf("PATCH memory failed status=%d body=%s", patchRec.Code, patchRec.Body.String())
	}
	var updated memories.MemoryDetail
	_ = json.Unmarshal(patchRec.Body.Bytes(), &updated)
	if !updated.Pinned || len(updated.MiniMemories) != 1 {
		t.Fatalf("expected pinned=true and 1 miniMemory, got %+v", updated)
	}

	// Check runs endpoint
	runsReq := httptest.NewRequest(http.MethodGet, "/api/v1/memories/consolidations", nil)
	runsReq.Header.Set("Authorization", "Bearer "+key.Token)
	runsRec := httptest.NewRecorder()
	mux.ServeHTTP(runsRec, runsReq)
	if runsRec.Code != http.StatusOK {
		t.Fatalf("GET consolidations failed status=%d body=%s", runsRec.Code, runsRec.Body.String())
	}
}
