package conversations_test

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
)

type stubPreviewAI struct{}

func (s *stubPreviewAI) Ready(_ context.Context) bool { return true }
func (s *stubPreviewAI) PreviewConversation(_ context.Context, _ string, conv ai.InputConversation, _ *ai.PreviewOutput, _ string) (ai.PreviewOutput, string, error) {
	return ai.PreviewOutput{
		TitleEn:      "Design Review",
		SummaryEn:    "Discussed module layout (" + conv.Segments[0].Text + ")",
		MemoryWorthy: true,
		Topics:       []string{"architecture"},
	}, "", nil
}

func TestGroupingBoundariesInsightsTimelineAndDelete(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS":
			return "5"
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
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}

	uid := "00000000-0000-0000-0000-000000000041"
	devID := "00000000-0000-0000-0000-000000000042"
	sessID := "00000000-0000-0000-0000-000000000043"
	srcID := "00000000-0000-0000-0000-000000000044"
	chkID := "00000000-0000-0000-0000-000000000045"

	_, err = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'convo', 'cv@x.io', 'h', 'user')`, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dev-cu', 'D', 'ios', 'mobile')`, devID, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
		VALUES (?, ?, ?, 'cu', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'ended')`, sessID, uid, devID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format)
		VALUES (?, ?, 'src-cu', 'microphone', 'mono', 16000, 'pcm_s16le')`, srcID, sessID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, state)
		VALUES (?, ?, ?, ?, 0, 'ik0', '0000000000000000000000000000000000000000000000000000000000000000', 100, 'wav', 'pcm', 'mono', '2026-04-01T10:00:00.000Z', 0, 5000, 'transcribed')`, chkID, uid, sessID, srcID)
	if err != nil {
		t.Fatal(err)
	}

	// Two segments 20 minutes apart -> GroupPendingSegments should create 2 conversations.
	_, err = db.W.ExecContext(ctx, `INSERT INTO transcript_segments (public_id, user_id, chunk_id, source_component, started_at, ended_at, chunk_start_ms, chunk_end_ms, text)
		VALUES ('seg-a', ?, ?, 'stt', '2026-04-01T10:00:00.000Z', '2026-04-01T10:01:00.000Z', 0, 1000, 'Let us review the module layout today'),
		       ('seg-b', ?, ?, 'stt', '2026-04-01T10:25:00.000Z', '2026-04-01T10:26:00.000Z', 1000, 2000, 'Second topic later in the hour')`,
		uid, chkID, uid, chkID)
	if err != nil {
		t.Fatal(err)
	}

	touched, err := conversations.GroupPendingSegments(ctx, db, cfg, uid)
	if err != nil || len(touched) != 2 {
		t.Fatalf("expected 2 conversations from 25m gap, got %v err=%v", touched, err)
	}

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	ins := &conversations.InsightService{
		DB: db, Cfg: func() config.Config { return cfg }, AI: &stubPreviewAI{}, Log: log,
	}
	res, err := ins.Execute(ctx, uid, touched[0])
	if err != nil || res["conversationId"] != touched[0] {
		t.Fatalf("insight execute unexpected: %+v err=%v", res, err)
	}

	tl, err := conversations.Timeline(ctx, db.R, uid, "20", "", "")
	if err != nil {
		t.Fatal(err)
	}
	items := tl["items"].([]conversations.ConversationRow)
	if len(items) != 2 {
		t.Fatalf("expected 2 timeline items, got %d", len(items))
	}

	svc := &conversations.Service{DB: db, Cfg: func() config.Config { return cfg }, Log: log}
	if _, err := svc.BulkRemove(ctx, uid, []string{touched[1]}); err != nil {
		t.Fatal(err)
	}
	rem, err := svc.List(ctx, uid, conversations.ListFilter{})
	if err != nil || len(rem) != 1 {
		t.Fatalf("expected 1 conversation left after delete, got %d err=%v", len(rem), err)
	}
}
