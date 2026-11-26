package worker_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/worker"
)

// A provider answering with an HTTP error must never cost the server its only
// copy of the audio while a retry, or a fix to the settings, can still happen.
func TestProviderHTTPErrorKeepsAudio(t *testing.T) {
	for _, tc := range []struct {
		name         string
		status       int
		wantAttempts int
	}{
		{"server error is retried", http.StatusInternalServerError, 1},
		{"rate limit is retried", http.StatusTooManyRequests, 1},
		{"rejected request is retried", http.StatusBadRequest, 1},
		{"bad key waits without using attempts", http.StatusUnauthorized, 0},
		{"wrong model waits without using attempts", http.StatusNotFound, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			runner, db, audio := chunkRunner(t)
			stt := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
			}))
			defer stt.Close()
			provider, err := transcription.NewProvider(transcription.RuntimeProviderConfig{
				Protocol: "openai", BaseURL: stt.URL, Model: "m",
			}, stt.Client())
			if err != nil {
				t.Fatal(err)
			}

			runner.TestTranscribeFn = func(ctx context.Context, _, path, _ string, _ []string, _ bool) ([]transcription.Segment, error) {
				return provider.Transcribe(ctx, transcription.TranscribeInput{Filename: path})
			}
			if ran, err := runner.RunOnce(ctx, "w"); err != nil || !ran {
				t.Fatalf("run: %v %v", ran, err)
			}

			var jobStatus, chunkState string
			var attempts int
			if err := db.R.QueryRowContext(ctx, `SELECT status, attempts FROM jobs WHERE resource_id='c'`).Scan(&jobStatus, &attempts); err != nil {
				t.Fatal(err)
			}
			if err := db.R.QueryRowContext(ctx, `SELECT state FROM audio_chunks WHERE id='c'`).Scan(&chunkState); err != nil {
				t.Fatal(err)
			}
			if jobStatus != "queued" || attempts != tc.wantAttempts || chunkState != "retryable_failed" {
				t.Fatalf("job %s attempts %d chunk %s", jobStatus, attempts, chunkState)
			}
			if _, err := os.Stat(audio); err != nil {
				t.Fatalf("audio was deleted: %v", err)
			}
		})
	}
}

// When the failure cannot even be recorded the job is still queued or leased, so
// its audio has to stay.
func TestUnrecordedFailureKeepsAudio(t *testing.T) {
	ctx := context.Background()
	runner, db, audio := chunkRunner(t)
	runner.TestTranscribeFn = func(ctx context.Context, _, _, _ string, _ []string, _ bool) ([]transcription.Segment, error) {
		if _, err := db.W.ExecContext(ctx, `UPDATE jobs SET lease_owner='another-worker'`); err != nil {
			t.Fatal(err)
		}
		return nil, errors.New("boom")
	}
	if _, err := runner.RunOnce(ctx, "w"); err == nil {
		t.Fatal("expected the unrecorded failure to be reported")
	}
	if _, err := os.Stat(audio); err != nil {
		t.Fatalf("audio was deleted: %v", err)
	}
}

// chunkRunner holds one uploaded chunk with its queued transcription job.
func chunkRunner(t *testing.T) (*worker.Runner, *dbx.DB, string) {
	t.Helper()
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
	if err := cfg.Paths.Ensure(); err != nil {
		t.Fatal(err)
	}
	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}

	audio := filepath.Join(cfg.Paths.AudioTmp, "chunk.wav")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO users (id, username, password_hash) VALUES ('u', 'u', 'x')`,
		`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES ('d', 'u', 'd', 'Phone', 'ios', 'mobile')`,
		`INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
					VALUES ('s', 'u', 'd', 's', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'active')`,
		`INSERT INTO recording_sources (id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format) VALUES ('src', 's', 'src', 'microphone', 'mono', 16000, 'pcm_s16le')`,
		`INSERT INTO audio_chunks (id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, monotonic_offset_ms, duration_ms, overlap_ms, state, temporary_path)
					VALUES ('c', 'u', 's', 'src', 0, 'k', '` + strings.Repeat("a", 64) + `', 5, 'wav', 'pcm_s16le', 'mono', '2026-04-01T10:00:00.000Z', 0, 5000, 0, 'uploaded', '` + audio + `')`,
	} {
		if _, err := db.W.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	cfgFn := func() config.Config { return cfg }
	jobSvc := &jobs.Service{DB: db, Cfg: cfgFn}
	if _, err := jobSvc.Enqueue(ctx, jobs.EnqueueInput{UserID: "u", ResourceType: "audio_chunk", ResourceID: "c", Type: "transcribe_chunk"}); err != nil {
		t.Fatal(err)
	}
	return &worker.Runner{DB: db, Cfg: cfgFn, Jobs: jobSvc, Proc: &processing.Service{DB: db, Cfg: cfgFn}}, db, audio
}
