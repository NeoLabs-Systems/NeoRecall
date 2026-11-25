package worker_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/NeoLabs-Systems/neorecall/internal/worker"
)

type stubWorkerAI struct{}

func (s *stubWorkerAI) Ready(_ context.Context) bool { return true }
func (s *stubWorkerAI) PreviewConversation(_ context.Context, _ string, conv ai.InputConversation, _ *ai.PreviewOutput, _ string) (ai.PreviewOutput, string, error) {
	return ai.PreviewOutput{TitleEn: "Synced", SummaryEn: "Preview " + conv.Segments[0].Text, MemoryWorthy: true}, "", nil
}

func TestWorkerTranscribeCleanupAndDetectBoundaries(t *testing.T) {
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
	regU, _, err := authSvc.Register(ctx, "worku", nil, "StrongPassword!1", auth.RequestContext{IPAddress: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	key, _ := authSvc.CreateAPIKey(ctx, regU.ID, "w-key", []string{"ingest:write", "devices:write"}, nil)

	jobSvc := &jobs.Service{DB: db, Cfg: cfgFn}
	procSvc := &processing.Service{DB: db, Cfg: cfgFn}
	setSvc := &settings.Service{DB: db, Cfg: cfgFn}
	tempA := &ingest.TempAudio{DB: db, Cfg: cfgFn, Log: log}
	receipts := &ingest.Receipts{DB: db}
	ingSvc := &ingest.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, TempAudio: tempA, Receipts: receipts}
	spkSvc := &speakers.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Proc: procSvc, Log: log}
	embSvc := &embeddings.Service{DB: db, Cfg: cfgFn, Jobs: jobSvc, Log: log}
	ctxSvc := &nctx.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Jobs: jobSvc, Settings: setSvc, Log: log}
	insSvc := &conversations.InsightService{DB: db, Cfg: cfgFn, Context: ctxSvc, Jobs: jobSvc, Settings: setSvc, AI: &stubWorkerAI{}, Log: log}
	memSvc := &memories.Service{DB: db, Cfg: cfgFn, Context: ctxSvc, Jobs: jobSvc, Log: log}

	mux := http.NewServeMux()
	(&ingest.Routes{Svc: ingSvc, Auth: &auth.Authenticator{Service: authSvc, Log: log}, Log: log}).Mount(mux)

	// Upload a chunk via real HTTP ingest route.
	uid := regU.ID
	devID := "00000000-0000-0000-0000-000000000091"
	sessID := "00000000-0000-0000-0000-000000000092"
	srcID := "00000000-0000-0000-0000-000000000093"
	_, _ = db.W.ExecContext(ctx, `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dc-1', 'Phone', 'ios', 'mobile')`, devID, uid)
	_, _ = db.W.ExecContext(ctx, `INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
		VALUES (?, ?, ?, 'sc-1', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'active')`, sessID, uid, devID)
	_, _ = db.W.ExecContext(ctx, `INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format)
		VALUES (?, ?, 'src-1', 'microphone', 'mono', 16000, 'pcm_s16le')`, srcID, sessID)

	audioPayload := []byte("RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00")
	sum := sha256.Sum256(audioPayload)
	sumHex := hex.EncodeToString(sum[:])
	var mpBuf bytes.Buffer
	mw := multipart.NewWriter(&mpBuf)
	fw, err := mw.CreateFormFile("audio", "chunk0.wav")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = fw.Write(audioPayload)
	_ = mw.Close()

	req := httptest.NewRequest(http.MethodPut, "/api/v1/ingest/sessions/"+sessID+"/sources/"+srcID+"/chunks/0", &mpBuf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+key.Token)
	req.Header.Set("Idempotency-Key", "k-w-1")
	req.Header.Set("X-Chunk-Sha256", sumHex)
	req.Header.Set("X-Chunk-Duration-Ms", "5000")
	req.Header.Set("X-Chunk-Overlap-Ms", "0")
	req.Header.Set("X-Channel-Layout", "mono")
	req.Header.Set("X-Monotonic-Offset-Ms", "0")
	req.Header.Set("X-Device-Started-At", "2026-04-01T10:00:00.000Z")
	req.Header.Set("X-Audio-Container", "wav")
	req.Header.Set("X-Audio-Codec", "pcm_s16le")
	req.Header.Set("X-Final-Chunk", "true")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("chunk upload failed: %d %s", rec.Code, rec.Body.String())
	}

	r := &worker.Runner{
		DB: db, Cfg: cfgFn, MasterKey: keyFn, Jobs: jobSvc, Proc: procSvc, Settings: setSvc,
		Usage: &usage.Service{DB: db, Cfg: cfgFn}, Speakers: spkSvc, Embeddings: embSvc,
		Context: ctxSvc, Insights: insSvc, Memories: memSvc, TempAudio: tempA, Log: log,
		TestTranscribeFn: func(_ context.Context, _, _, _ string, _ []string, _ bool) ([]transcription.Segment, error) {
			return []transcription.Segment{{Text: "Hello worker pipeline", StartMs: 100, EndMs: 1500, SourceComponent: "combined"}}, nil
		},
	}

	// Drain queued transcribe_chunk + detect_boundaries (+ ignore embed job by overriding VectorReady=false)
	for i := 0; i < 6; i++ {
		did, err := r.RunOnce(ctx, "test-worker")
		if err != nil {
			t.Fatal(err)
		}
		if !did {
			break
		}
	}

	// Verify chunk reached terminal transcribed state and temporary_path is NULL.
	var st string
	var tpNull *string
	if err := db.R.QueryRowContext(ctx, `SELECT state, temporary_path FROM audio_chunks WHERE user_id=?`, uid).Scan(&st, &tpNull); err != nil {
		t.Fatal(err)
	}
	if st != "transcribed" || tpNull != nil {
		t.Fatalf("expected transcribed & NULL temporary_path, got state=%s tp=%v", st, tpNull)
	}
	// Verify conversation was grouped cleanly by detect_boundaries.
	var convCnt int
	_ = db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE user_id=?`, uid).Scan(&convCnt)
	if convCnt != 1 {
		t.Fatalf("expected 1 grouped conversation, got %d", convCnt)
	}
}
