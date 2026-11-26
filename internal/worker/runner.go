package worker

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/providers"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/google/uuid"
)

type codedErr struct {
	code      string
	msg       string
	retryable bool
}

func (e *codedErr) Error() string { return e.msg }

type Runner struct {
	DB             *dbx.DB
	Cfg            func() config.Config
	MasterKey      func() ([]byte, error)
	Jobs           *jobs.Service
	Providers      *providers.Service
	Proc           *processing.Service
	Settings       *settings.Service
	Usage          *usage.Service
	Speakers       *speakers.Service
	Embeddings     *embeddings.Service
	Context        *nctx.Service
	Insights       *conversations.InsightService
	Memories       *memories.Service
	Consolidations *memories.ConsolidationService
	Imports        *ingest.ImportService
	TempAudio      *ingest.TempAudio
	Backups        *backup.Service
	Cloud          *cloud.Service
	LocalAnalyzer  *transcription.LocalAnalyzer
	Log            *slog.Logger

	// Optional hook in unit tests.
	TestTranscribeFn func(ctx context.Context, chunkID, plainAudioPath, layout string, vocab []string, vocabCorr bool) ([]transcription.Segment, error)
}

func (r *Runner) cfg() config.Config {
	if r.Cfg != nil {
		return r.Cfg()
	}
	return config.Config{}
}

func (r *Runner) isInferenceReady(ctx context.Context) bool {
	if r.TestTranscribeFn != nil {
		return true
	}
	if r.Providers == nil {
		return false
	}
	p, err := r.Providers.TranscriptionProvider(ctx)
	return err == nil && p != nil && p.Ready()
}

func (r *Runner) writeHeartbeat(ctx context.Context, workerID, jobID, state string) {
	host, _ := os.Hostname()
	var jNull any
	if jobID != "" {
		jNull = jobID
	}
	now := timeutil.NowISO()
	_, _ = r.DB.W.ExecContext(ctx, `INSERT INTO worker_heartbeats (worker_id, host, role, process_id, model_state, current_job_id, started_at, heartbeat_at)
		VALUES (?, ?, 'processor', ?, ?, ?, ?, ?)
		ON CONFLICT(worker_id) DO UPDATE SET model_state=excluded.model_state, current_job_id=excluded.current_job_id,
			process_id=excluded.process_id, heartbeat_at=excluded.heartbeat_at`,
		workerID, host, os.Getpid(), state, jNull, now, now)
}

// RunOnce processes at most one job and returns whether work was claimed (useful for deterministic tests and draining).
func (r *Runner) RunOnce(ctx context.Context, workerID string) (bool, error) {
	canTranscribe := r.isInferenceReady(ctx)
	j, err := r.Jobs.ClaimNext(ctx, workerID, r.cfg().JobLeaseMs, canTranscribe)
	if err != nil {
		return false, err
	}
	if j == nil {
		return false, nil
	}
	stopLease := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		iv := time.Duration(max(5_000, r.cfg().WorkerLeaseRenewMs)) * time.Millisecond
		t := time.NewTicker(iv)
		defer t.Stop()
		for {
			select {
			case <-stopLease:
				return
			case <-t.C:
				_, _ = r.DB.W.ExecContext(ctx, `UPDATE jobs SET lease_expires_at=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
					WHERE id=? AND lease_owner=? AND status='leased'`,
					timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), r.cfg().JobLeaseMs)), j.ID, workerID)
			}
		}
	}()

	err = r.handleJob(ctx, j)
	close(stopLease)
	wg.Wait()

	if err == nil {
		_ = r.Jobs.Complete(ctx, j.ID, workerID)
		return true, nil
	}

	var ule *usage.LimitExceededError
	if errors.As(err, &ule) {
		r.Jobs.Defer(ctx, j.ID, workerID, ule.RetryAt, "USAGE_LIMIT_EXCEEDED", "Waiting for the account usage window to open.")
		return true, nil
	}

	code, msg, retryable := classifyJobError(err)
	var pe *transcription.ProviderError
	if j.Type == "transcribe_chunk" && errors.As(err, &pe) && pe.NeedsUserFix() {
		retryAt := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), r.cfg().JobRetryMaxMs))
		if r.Jobs.Defer(ctx, j.ID, workerID, retryAt, code, msg) {
			r.markChunkFailure(ctx, j, code, msg, true)
		}
		return true, nil
	}
	willRetry, failErr := r.Jobs.Fail(ctx, j.ID, workerID, code, msg, retryable)
	if failErr != nil {
		// The job still holds its place in the queue, so its audio must too.
		return true, failErr
	}
	r.markChunkFailure(ctx, j, code, msg, willRetry)
	return true, nil
}

func (r *Runner) Start(ctx context.Context) {
	c := r.cfg()
	host, _ := os.Hostname()
	workerID := fmt.Sprintf("%s-%d-%s", host, os.Getpid(), uuid.NewString()[:8])
	r.writeHeartbeat(ctx, workerID, "", "starting")
	defer func() {
		_, _ = r.DB.W.ExecContext(context.Background(), `DELETE FROM worker_heartbeats WHERE worker_id=?`, workerID)
	}()

	hbStop := make(chan struct{})
	go func() {
		iv := time.Duration(max(2_000, c.WorkerHeartbeatMs)) * time.Millisecond
		t := time.NewTicker(iv)
		defer t.Stop()
		for {
			select {
			case <-hbStop:
				return
			case <-t.C:
				st := "not_ready"
				if r.isInferenceReady(ctx) {
					st = "ready"
				}
				r.writeHeartbeat(ctx, workerID, "", st)
			}
		}
	}()
	defer close(hbStop)

	pollWait := time.Duration(max(200, c.WorkerIdlePollMs)) * time.Millisecond
	for {
		if ctx.Err() != nil {
			return
		}
		didWork, err := r.RunOnce(ctx, workerID)
		if err != nil && r.Log != nil {
			r.Log.Warn("Worker poll failed", "error", err)
		}
		if didWork {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(pollWait):
		}
	}
}

func classifyJobError(err error) (code, msg string, retryable bool) {
	msg = err.Error()
	code = "JOB_FAILED"
	retryable = true
	var ce *codedErr
	if errors.As(err, &ce) {
		return ce.code, ce.msg, ce.retryable
	}
	var pe *transcription.ProviderError
	if errors.As(err, &pe) {
		return pe.Code, pe.Message, !pe.Permanent
	}
	var ae *ai.AIError
	if errors.As(err, &ae) && ae.Code != "" {
		return ae.Code, ae.Message, ai.TransientAICodes[ae.Code]
	}
	return code, msg, retryable
}

func (r *Runner) markChunkFailure(ctx context.Context, j *jobs.Job, code, msg string, willRetry bool) {
	if j.Type != "transcribe_chunk" {
		return
	}
	if len(msg) > 500 {
		msg = msg[:500]
	}
	var state, srcID, uid, sTP string
	rows, err := r.DB.R.QueryContext(ctx, `SELECT state, source_id, user_id, COALESCE(temporary_path,'') FROM audio_chunks WHERE id=?`, j.ResourceID)
	if err != nil {
		return
	}
	if !rows.Next() {
		rows.Close()
		return
	}
	_ = rows.Scan(&state, &srcID, &uid, &sTP)
	rows.Close()
	hasTP := sTP != ""
	if state == "persisted_cleanup_pending" {
		return
	}
	if willRetry {
		_, _ = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='retryable_failed', error_code=?, error_message=?,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, code, msg, j.ResourceID)
		return
	}
	var srcKind string
	_ = r.DB.R.QueryRowContext(ctx, `SELECT kind FROM recording_sources WHERE id=?`, srcID).Scan(&srcKind)
	if srcKind == "import" {
		exp := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), int64(max(1, r.cfg().ImportFailedTTLHours))*60*60_000))
		_, _ = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='retryable_failed', error_code=?, error_message=?,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, code, msg, j.ResourceID)
		_, _ = r.DB.W.ExecContext(ctx, `UPDATE imports SET state='failed', error_code=?, expires_at=?,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=?
			AND id=(SELECT substr(client_uuid, 15) FROM recording_sources WHERE id=?)`, code, exp, uid, srcID)
		return
	}
	if hasTP {
		if err := ingest.UnlinkStrict(sTP); err != nil {
			_, _ = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='retryable_failed', error_code='AUDIO_CLEANUP_FAILED', error_message=?,
				updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, err.Error(), j.ResourceID)
			_, _ = r.Jobs.Enqueue(ctx, jobs.EnqueueInput{
				UserID: uid, ResourceType: "audio_chunk", ResourceID: j.ResourceID,
				Type: "cleanup_chunk_audio", Priority: 110,
			})
			return
		}
	}
	_, _ = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='reupload_required', temporary_path=NULL,
		error_code=?, error_message=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, code, msg, j.ResourceID)
}

func sha256JSON(v any) string {
	b, _ := json.Marshal(v)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
