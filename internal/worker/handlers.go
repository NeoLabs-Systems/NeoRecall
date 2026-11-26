package worker

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/google/uuid"
)

func (r *Runner) handleJob(ctx context.Context, j *jobs.Job) error {
	switch j.Type {
	case "transcribe_chunk":
		return r.handleTranscribe(ctx, j)
	case "cleanup_chunk_audio", "sweep_temp_audio":
		return r.handleCleanup(ctx, j)
	case "embed_search_documents":
		if r.Embeddings == nil {
			return nil
		}
		ids := embeddings.ParseDocumentIDs(j.PayloadJSON)
		if len(ids) == 0 {
			return nil
		}
		return r.Embeddings.EmbedDocuments(ctx, ids)
	case "detect_boundaries":
		_, _ = conversations.CloseQuietOpenConversations(ctx, r.DB, r.cfg(), j.UserID)
		touched, err := conversations.GroupPendingSegments(ctx, r.DB, r.cfg(), j.UserID)
		if err != nil {
			return err
		}
		for _, cid := range touched {
			if r.Embeddings != nil {
				_, _ = conversations.ReevaluateConversation(ctx, r.DB, r.Embeddings, r.cfg(), j.UserID, cid)
			}
			var st string
			if r.DB.R.QueryRowContext(ctx, `SELECT state FROM conversations WHERE id=?`, cid).Scan(&st) == nil && st == "closed" && r.Jobs != nil {
				_, _ = r.Jobs.Enqueue(ctx, jobs.EnqueueInput{
					UserID: j.UserID, ResourceType: "conversation", ResourceID: cid,
					Type: "resolve_speakers", Priority: 30,
				})
			}
		}
		return nil
	case "resolve_speakers":
		if r.Speakers == nil {
			return nil
		}
		var state string
		if r.DB.R.QueryRowContext(ctx, `SELECT state FROM conversations WHERE id=? AND user_id=?`, j.ResourceID, j.UserID).Scan(&state) != nil {
			return nil
		}
		if r.Settings != nil {
			if st, err := r.Settings.Get(ctx, j.UserID); err == nil {
				if v, ok := st["deferredSpeakerResolution"].(bool); ok && !v {
					return nil
				}
			}
		}
		_, err := r.Speakers.ResolveConversation(ctx, j.UserID, j.ResourceID)
		return err
	case "reconcile_speakers":
		if r.Speakers == nil {
			return nil
		}
		if r.Settings != nil {
			if st, err := r.Settings.Get(ctx, j.UserID); err == nil {
				if v, ok := st["recurringSpeakerMatching"].(bool); ok && !v {
					return nil
				}
			}
		}
		_, err := r.Speakers.Reevaluate(ctx, j.UserID, false)
		return err
	case "preview_conversation":
		if r.Insights == nil {
			return nil
		}
		_, err := r.Insights.Execute(ctx, j.UserID, j.ResourceID)
		return err
	case "consolidate_memories":
		if r.Consolidations == nil {
			return nil
		}
		var p struct {
			RunID           string   `json:"runId"`
			ConversationIDs []string `json:"conversationIds"`
		}
		_ = json.Unmarshal([]byte(j.PayloadJSON), &p)
		if p.RunID == "" {
			p.RunID = j.ResourceID
		}
		return r.Consolidations.Execute(ctx, j.UserID, p.RunID, p.ConversationIDs)
	case "rewrite_merged_memory":
		if r.Memories == nil {
			return nil
		}
		var p struct {
			PublicID string                `json:"publicId"`
			Inputs   []ai.MemoryMergeInput `json:"inputs"`
		}
		_ = json.Unmarshal([]byte(j.PayloadJSON), &p)
		if p.PublicID == "" {
			p.PublicID = j.ResourceID
		}
		return r.Memories.ExecuteRewriteMerged(ctx, j.UserID, p.PublicID, p.Inputs)
	case "analyze_context", "analyze_context_item":
		if r.Context == nil {
			return nil
		}
		return r.Context.AnalyzeItem(ctx, j.UserID, j.ResourceID)
	case "rewrite_memory_context", "rewrite_memory_with_context":
		if r.Memories == nil {
			return nil
		}
		var p struct {
			MemoryID int64 `json:"memoryId"`
		}
		_ = json.Unmarshal([]byte(j.PayloadJSON), &p)
		memID := p.MemoryID
		if memID == 0 {
			_ = r.DB.R.QueryRowContext(ctx, `SELECT id FROM memories WHERE public_id=? AND user_id=?`, j.ResourceID, j.UserID).Scan(&memID)
		}
		if memID == 0 {
			return nil
		}
		_, err := r.Memories.RewriteWithContext(ctx, j.UserID, memID)
		return err
	case "maintenance", "prune_events":
		return r.handleMaintenance(ctx, j)
	case "process_import":
		return r.handleProcessImport(ctx, j)
	case "backup":
		if r.Backups == nil {
			return nil
		}
		_, err := r.Backups.Run(ctx, "scheduled")
		return err
	case "cloud_put":
		if r.Cloud == nil {
			return nil
		}
		_, err := r.Cloud.Drain(ctx, j.UserID)
		return err
	case "cloud_user_backup":
		if r.Cloud == nil {
			return nil
		}
		var p struct {
			TriggerKind string `json:"triggerKind"`
		}
		_ = json.Unmarshal([]byte(j.PayloadJSON), &p)
		_, err := r.Cloud.BackupUserData(ctx, j.UserID, p.TriggerKind == "manual")
		return err
	default:
		return &codedErr{code: "UNKNOWN_JOB_TYPE", msg: "Unknown job type: " + j.Type, retryable: false}
	}
}

func (r *Runner) handleCleanup(ctx context.Context, j *jobs.Job) error {
	if j.Type == "sweep_temp_audio" {
		if r.TempAudio != nil {
			_, _ = r.TempAudio.Sweep(ctx)
		}
		if r.Cloud != nil {
			r.Cloud.SweepPending(ctx)
		}
		return nil
	}
	var state string
	var tempPath sql.NullString
	var segCount int
	err := r.DB.R.QueryRowContext(ctx, `SELECT state, temporary_path, transcript_segment_count FROM audio_chunks
		WHERE id=? AND state IN ('persisted_cleanup_pending','retryable_failed')`, j.ResourceID).
		Scan(&state, &tempPath, &segCount)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if state == "persisted_cleanup_pending" {
		var srcID, sessID, uid string
		_ = r.DB.R.QueryRowContext(ctx, `SELECT source_id, session_id, user_id FROM audio_chunks WHERE id=?`, j.ResourceID).Scan(&srcID, &sessID, &uid)
		return r.finishCleanup(ctx, j.ResourceID, uid, sessID, srcID, 0, tempPath.String, segCount)
	}
	if tempPath.Valid && tempPath.String != "" {
		if err := ingest.UnlinkStrict(tempPath.String); err != nil {
			return err
		}
	}
	_, err = r.DB.W.ExecContext(ctx, `UPDATE audio_chunks SET state='reupload_required', temporary_path=NULL,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, j.ResourceID)
	return err
}

func (r *Runner) handleMaintenance(ctx context.Context, j *jobs.Job) error {
	c := r.cfg()
	if j.Type == "prune_events" {
		_, _ = r.DB.W.ExecContext(ctx, `DELETE FROM event_outbox WHERE expires_at<?`, timeutil.NowISO())
		cutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -c.AskQuotaRetentionMs))
		_, _ = r.DB.W.ExecContext(ctx, `DELETE FROM ask_quota_events WHERE attempted_at<?`, cutoff)
		return nil
	}

	// Unblock consolidation runs left stranded by a crashed worker without triggering quarantine.
	intCutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -c.ConsolidationInterruptMs))
	_, _ = r.DB.W.ExecContext(ctx, `UPDATE consolidation_runs SET state='failed', error_code='WORKER_INTERRUPTED',
		error_message='The worker process did not complete this run.', completed_at=?
		WHERE state IN ('reserved','running') AND reserved_at<?`, timeutil.NowISO(), intCutoff)

	// Finalize older provisional daily summaries.
	today := time.Now().UTC().Format("2006-01-02")
	_, _ = r.DB.W.ExecContext(ctx, `UPDATE daily_summaries SET state='final', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE state='provisional' AND local_date<?`, today)

	if r.Imports != nil {
		_, _ = r.Imports.ReconcileProcessing(ctx)
		_ = r.Imports.SweepOrphans(ctx)
	}
	if r.Context != nil {
		r.Context.PurgeExpiredOriginals(ctx)
	}

	rows, _ := r.DB.R.QueryContext(ctx, `SELECT id FROM users WHERE disabled_at IS NULL`)
	var userIDs []string
	if rows != nil {
		for rows.Next() {
			var u string
			if rows.Scan(&u) == nil {
				userIDs = append(userIDs, u)
			}
		}
		rows.Close()
	}

	var procCfg = r.Proc.Get(ctx)
	for _, uid := range userIDs {
		recMatch, defRes := true, true
		if r.Settings != nil {
			if st, err := r.Settings.Get(ctx, uid); err == nil {
				if v, ok := st["recurringSpeakerMatching"].(bool); ok {
					recMatch = v
				}
				if v, ok := st["deferredSpeakerResolution"].(bool); ok {
					defRes = v
				}
			}
		}
		if r.Speakers != nil {
			if recMatch {
				_, _ = r.Speakers.Reevaluate(ctx, uid, false)
			}
			if defRes {
				r.Speakers.SweepUnresolvedConversations(ctx, uid)
			}
		}
		if r.Memories != nil {
			_, _ = r.Memories.SweepDuplicates(ctx, uid, procCfg)
		}
	}

	// Clean expired failed imports.
	expRows, _ := r.DB.R.QueryContext(ctx, `SELECT id, user_id, temporary_path FROM imports WHERE state='failed' AND expires_at<?`, timeutil.NowISO())
	if expRows != nil {
		type expRow struct {
			id, uid string
			tp      sql.NullString
		}
		var exps []expRow
		for expRows.Next() {
			var e expRow
			if expRows.Scan(&e.id, &e.uid, &e.tp) == nil {
				exps = append(exps, e)
			}
		}
		expRows.Close()
		for _, e := range exps {
			if e.tp.Valid && e.tp.String != "" {
				_ = os.Remove(e.tp.String)
			}
			var sessID string
			if r.DB.R.QueryRowContext(ctx, `SELECT id FROM recording_sessions WHERE user_id=? AND client_uuid=?`, e.uid, "import-"+e.id).Scan(&sessID) == nil && sessID != "" {
				crows, _ := r.DB.R.QueryContext(ctx, `SELECT temporary_path FROM audio_chunks WHERE session_id=? AND temporary_path IS NOT NULL`, sessID)
				if crows != nil {
					for crows.Next() {
						var p string
						if crows.Scan(&p) == nil && p != "" {
							_ = os.Remove(p)
						}
					}
					crows.Close()
				}
				_, _ = r.DB.W.ExecContext(ctx, `DELETE FROM recording_sessions WHERE id=?`, sessID)
			}
			_, _ = r.DB.W.ExecContext(ctx, `UPDATE imports SET temporary_path=NULL, state='cancelled', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, e.id)
		}
	}
	return nil
}

func (r *Runner) handleProcessImport(ctx context.Context, j *jobs.Job) error {
	c := r.cfg()
	var id, userID, origName, createdAt string
	var tempPath, deviceID, captureTime, timezone sql.NullString
	err := r.DB.R.QueryRowContext(ctx, `SELECT id, user_id, temporary_path, device_id, original_name, capture_time, timezone, created_at
		FROM imports WHERE id=? AND user_id=? AND state='assembled'`, j.ResourceID, j.UserID).
		Scan(&id, &userID, &tempPath, &deviceID, &origName, &captureTime, &timezone, &createdAt)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if !tempPath.Valid || tempPath.String == "" {
		return fmt.Errorf("import source missing")
	}

	failImport := func(code string, cause error) error {
		exp := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), int64(max(1, c.ImportFailedTTLHours))*60*60_000))
		_, _ = r.DB.W.ExecContext(ctx, `UPDATE imports SET state='failed', error_code=?, expires_at=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
			code, exp, id)
		return cause
	}

	ff := transcription.ResolveFFmpegPath()
	if ff == "" {
		// A missing decoder is the installation's fault: leave the import
		// assembled so the retry, or a fixed install, can still use the upload.
		return &codedErr{code: "IMPORT_DECODE_FAILED", msg: "ffmpeg is not available to decode import", retryable: true}
	}
	key, err := r.MasterKey()
	if err != nil {
		return err
	}
	plainSrc, err := crypto.ReadSealedFile(key, tempPath.String)
	if err != nil {
		return err
	}
	workDir := filepath.Join(c.Paths.AudioTmp, "import-"+id)
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(workDir)

	inFile := filepath.Join(workDir, "source.bin")
	if err := os.WriteFile(inFile, plainSrc, 0o600); err != nil {
		return err
	}
	pattern := filepath.Join(workDir, "chunk-%08d.wav")
	segTime := strconv.FormatFloat(float64(max(1000, c.ChunkTargetMs))/1000.0, 'f', 3, 64)
	cmd := exec.CommandContext(ctx, ff, "-v", "error", "-i", inFile, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
		"-f", "segment", "-segment_time", segTime, "-reset_timestamps", "1", pattern)
	if out, err := cmd.CombinedOutput(); err != nil {
		return failImport("IMPORT_DECODE_FAILED", fmt.Errorf("import decode failed: %s", strings.TrimSpace(string(out))))
	}
	_ = os.Remove(inFile)

	entries, _ := os.ReadDir(workDir)
	var files []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".wav") {
			files = append(files, filepath.Join(workDir, e.Name()))
		}
	}
	sort.Strings(files)
	if len(files) == 0 {
		return failImport("IMPORT_EMPTY", &codedErr{code: "IMPORT_EMPTY", msg: "Import contained no decodable audio.", retryable: false})
	}

	durations := make([]int, len(files))
	var totalDurMs int64
	for i, f := range files {
		raw, rerr := os.ReadFile(f)
		if rerr != nil {
			return failImport("IMPORT_SEGMENT_INVALID", rerr)
		}
		d := speakers.WavDurationMs(raw)
		if d <= 0 {
			return failImport("IMPORT_SEGMENT_INVALID", fmt.Errorf("WAV metadata incomplete in %s", filepath.Base(f)))
		}
		durations[i] = d
		totalDurMs += int64(d)
	}

	// Ensure import device
	devID := deviceID.String
	if devID == "" {
		_ = r.DB.R.QueryRowContext(ctx, `SELECT id FROM devices WHERE user_id=? AND kind='import' AND client_uuid='neorecall-import-service'`, userID).Scan(&devID)
		if devID == "" {
			devID = uuid.NewString()
			_, err = r.DB.W.ExecContext(ctx, `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'neorecall-import-service', 'Audio imports', 'server', 'import')`, devID, userID)
			if err != nil {
				return err
			}
		}
	}

	startedAt := createdAt
	if captureTime.Valid && captureTime.String != "" {
		startedAt = captureTime.String
	}
	tStart, _ := timeutil.ParseISO(startedAt)
	if tStart.IsZero() {
		tStart = time.Now().UTC()
	}
	endedAt := timeutil.FormatISO(timeutil.AddMillis(tStart, totalDurMs))
	tz := "UTC"
	if timezone.Valid && timezone.String != "" {
		tz = timezone.String
	}

	sourceID := uuid.NewString()
	sessID := uuid.NewString()
	metaJSON, _ := json.Marshal(map[string]any{"importId": id, "originalName": origName})

	var movedFiles []string
	tx, err := r.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() {
		if tx != nil {
			_ = tx.Rollback()
			for _, f := range movedFiles {
				_ = os.Remove(f)
			}
		}
	}()

	if _, err := tx.ExecContext(ctx, `INSERT INTO recording_sessions
		(id, user_id, device_id, client_uuid, device_started_at, device_ended_at, corrected_started_at, corrected_ended_at, timezone, consent_attested_at, status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ended')`,
		sessID, userID, devID, "import-"+id, startedAt, endedAt, startedAt, endedAt, tz, createdAt); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO recording_sources
		(id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format, final_sequence, closed_at, metadata_json)
		VALUES (?, ?, ?, 'import', 'mono', 16000, 'pcm_s16le', ?, ?, ?)`,
		sourceID, sessID, "import-source-"+id, len(files)-1, timeutil.NowISO(), string(metaJSON)); err != nil {
		return err
	}

	var offsetMs int64
	for seq, srcFile := range files {
		durMs := max(1, durations[seq])
		chkID := uuid.NewString()
		dest := filepath.Join(c.Paths.AudioTmp, chkID+".wav")
		if err := os.Rename(srcFile, dest); err != nil {
			raw, rerr := os.ReadFile(srcFile)
			if rerr != nil {
				return rerr
			}
			if werr := os.WriteFile(dest, raw, 0o600); werr != nil {
				return werr
			}
		}
		movedFiles = append(movedFiles, dest)
		st, _ := os.Stat(dest)
		digest, _ := sha256HexFile(dest)
		if err := crypto.SealInPlace(key, dest); err != nil {
			return err
		}
		devStart := timeutil.FormatISO(timeutil.AddMillis(tStart, offsetMs))
		if _, err := tx.ExecContext(ctx, `INSERT INTO audio_chunks
			(id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec,
			 channel_layout, device_started_at, monotonic_offset_ms, duration_ms, overlap_ms, state, temporary_path)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'wav', 'pcm_s16le', 'mono', ?, ?, ?, 0, 'uploaded', ?)`,
			chkID, userID, sessID, sourceID, seq, fmt.Sprintf("import:%s:%d", id, seq), digest, st.Size(),
			devStart, offsetMs, durMs, dest); err != nil {
			return err
		}
		_, _ = jobs.EnqueueTx(ctx, tx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "audio_chunk", ResourceID: chkID,
			Type: "transcribe_chunk", Priority: 70,
		}, c.JobMaxAttempts)
		offsetMs += int64(durMs)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE imports SET state='processing', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	tx = nil
	return nil
}

func sha256HexFile(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	raw, err := io.ReadAll(f)
	if err != nil {
		return "", err
	}
	return crypto.SHA256Hex(string(raw)), nil
}

var _ = cloud.Service{}
var _ = config.Config{}
var _ = slog.Logger{}
var _ = http.StatusOK
