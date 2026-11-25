package cloud

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

const (
	audioPutPriority   = 40
	dataBackupPriority = -25
)

var partFileRe = regexp.MustCompile(`^(\d+)\.[A-Za-z0-9]+$`)

func (s *Service) pendingDir() string {
	dir := s.cfg().Paths.CloudPending
	if dir == "" {
		return ""
	}
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

func (s *Service) sinkFor(ctx context.Context, userID string) (Sink, error) {
	acc, secEnc, err := s.GetAccount(ctx, userID)
	if err != nil {
		return nil, err
	}
	if acc == nil || secEnc == "" {
		return nil, &SinkError{Code: "CLOUD_NOT_CONNECTED", Retryable: false, Message: "No cloud backup is connected."}
	}
	cred, err := s.decryptSecret(secEnc)
	if err != nil {
		return nil, err
	}
	if acc.Type == "neocloud" {
		return &neoCloudSink{
			baseURL: acc.BaseURL, token: cred, folder: acc.Folder,
			http: s.httpClient(), timeoutMs: s.cfg().CloudHTTPTimeoutMs,
		}, nil
	}
	return &webDAVSink{
		baseURL: acc.BaseURL, username: acc.Username, password: cred, folder: acc.Folder,
		http: s.httpClient(), timeoutMs: s.cfg().CloudHTTPTimeoutMs,
	}, nil
}

func (s *Service) EnqueuePut(ctx context.Context, userID string) {
	if s.Jobs == nil {
		return
	}
	_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
		UserID: userID, ResourceType: "user", ResourceID: "cloud-put-" + userID,
		Type: "cloud_put", Priority: audioPutPriority,
	})
}

func (s *Service) EnqueueDataBackup(ctx context.Context, userID, triggerKind string) {
	if s.Jobs == nil {
		return
	}
	_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
		UserID: userID, ResourceType: "user", ResourceID: "cloud-backup-" + userID,
		Type: "cloud_user_backup", Priority: dataBackupPriority,
		Payload: map[string]any{"triggerKind": triggerKind},
	})
}

type AudioChunkInfo struct {
	ID            string
	UserID        string
	SessionID     string
	SourceID      string
	Sequence      int
	TemporaryPath string
}

// StageAudio copies a transcribed audio chunk into sealed local staging for full-session concatenation.
func (s *Service) StageAudio(ctx context.Context, chunk AudioChunkInfo) error {
	if chunk.TemporaryPath == "" {
		return nil
	}
	if _, err := os.Stat(chunk.TemporaryPath); err != nil {
		return nil
	}
	acc, _, err := s.GetAccount(ctx, chunk.UserID)
	if err != nil || acc == nil || !acc.AudioEnabled {
		return nil
	}
	key, err := s.MasterKey()
	if err != nil {
		return err
	}

	var asmID, asmDir string
	err = s.DB.R.QueryRowContext(ctx, `SELECT id, local_dir FROM cloud_recording_assemblies
		WHERE user_id=? AND session_id=? AND source_id=? AND state='assembling'`,
		chunk.UserID, chunk.SessionID, chunk.SourceID).Scan(&asmID, &asmDir)
	if err == sql.ErrNoRows {
		var sessStart, srcKind string
		if s.DB.R.QueryRowContext(ctx, `SELECT device_started_at FROM recording_sessions WHERE id=?`, chunk.SessionID).Scan(&sessStart) != nil {
			return nil
		}
		if s.DB.R.QueryRowContext(ctx, `SELECT kind FROM recording_sources WHERE id=?`, chunk.SourceID).Scan(&srcKind) != nil {
			return nil
		}
		asmID = uuid.NewString()
		asmDir = filepath.Join(s.pendingDir(), "assemblies", asmID)
		_ = os.MkdirAll(asmDir, 0o700)
		t, err := timeutil.ParseISO(sessStart)
		if err != nil {
			t = time.Now().UTC()
		}
		remPath := fmt.Sprintf("audio/%s/%s-%s-%s.wav",
			t.UTC().Format("2006-01-02"), t.UTC().Format("20060102T150405Z"), sanitizeKindSlug(srcKind), chunk.SourceID[:min(8, len(chunk.SourceID))])
		_, ierr := s.DB.W.ExecContext(ctx, `INSERT INTO cloud_recording_assemblies
			(id, user_id, account_id, session_id, source_id, local_dir, remote_path, state)
			VALUES (?, ?, ?, ?, ?, ?, ?, 'assembling')`,
			asmID, chunk.UserID, acc.ID, chunk.SessionID, chunk.SourceID, asmDir, remPath)
		if ierr != nil {
			_ = os.RemoveAll(asmDir)
			if s.DB.R.QueryRowContext(ctx, `SELECT id, local_dir FROM cloud_recording_assemblies
				WHERE user_id=? AND session_id=? AND source_id=? AND state='assembling'`,
				chunk.UserID, chunk.SessionID, chunk.SourceID).Scan(&asmID, &asmDir) != nil {
				return ierr
			}
		}
	} else if err != nil {
		return err
	}

	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(chunk.TemporaryPath)), ".")
	if ext == "" {
		ext = "bin"
	}
	dest := filepath.Join(asmDir, fmt.Sprintf("%06d.%s", chunk.Sequence, ext))
	plain, err := crypto.ReadSealedFile(key, chunk.TemporaryPath)
	if err != nil {
		return err
	}
	if err := os.WriteFile(dest, plain, 0o600); err != nil {
		return err
	}
	if err := crypto.SealInPlace(key, dest); err != nil {
		return err
	}

	var sessStatus string
	var closedAt sql.NullString
	_ = s.DB.R.QueryRowContext(ctx, `SELECT status FROM recording_sessions WHERE id=?`, chunk.SessionID).Scan(&sessStatus)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT closed_at FROM recording_sources WHERE id=?`, chunk.SourceID).Scan(&closedAt)
	if sessStatus != "active" || closedAt.Valid {
		s.EnqueuePut(ctx, chunk.UserID)
	}
	return nil
}

func (s *Service) FinalizeSession(ctx context.Context, sessionID string) {
	var uid string
	if s.DB.R.QueryRowContext(ctx, `SELECT user_id FROM recording_sessions WHERE id=?`, sessionID).Scan(&uid) == nil && uid != "" {
		s.EnqueuePut(ctx, uid)
	}
}

func (s *Service) assemblyReady(ctx context.Context, sessionID, sourceID string) bool {
	var status string
	if s.DB.R.QueryRowContext(ctx, `SELECT status FROM recording_sessions WHERE id=?`, sessionID).Scan(&status) == nil && status == "active" {
		var closedAt sql.NullString
		if s.DB.R.QueryRowContext(ctx, `SELECT closed_at FROM recording_sources WHERE id=?`, sourceID).Scan(&closedAt) != nil || !closedAt.Valid {
			return false
		}
	}
	var unfinished int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks WHERE source_id=? AND state NOT IN ('transcribed','silent')`, sourceID).Scan(&unfinished)
	return unfinished == 0
}

func (s *Service) finalizeReadyAssemblies(ctx context.Context, userID string) int {
	key, err := s.MasterKey()
	if err != nil {
		return 0
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, account_id, session_id, source_id, local_dir, remote_path
		FROM cloud_recording_assemblies WHERE user_id=? AND state='assembling'`, userID)
	if err != nil {
		return 0
	}
	type asm struct {
		id, accID, sessID, srcID, dir, remPath string
	}
	var list []asm
	for rows.Next() {
		var a asm
		if rows.Scan(&a.id, &a.accID, &a.sessID, &a.srcID, &a.dir, &a.remPath) == nil {
			list = append(list, a)
		}
	}
	rows.Close()

	queued := 0
	for _, a := range list {
		if !s.assemblyReady(ctx, a.sessID, a.srcID) {
			continue
		}
		ovMap := make(map[int]int64)
		orows, _ := s.DB.R.QueryContext(ctx, `SELECT sequence, overlap_ms FROM audio_chunks WHERE source_id=?`, a.srcID)
		if orows != nil {
			for orows.Next() {
				var seq int
				var ov int64
				if orows.Scan(&seq, &ov) == nil {
					ovMap[seq] = ov
				}
			}
			orows.Close()
		}
		entries, err := os.ReadDir(a.dir)
		var parts []audioPart
		if err == nil {
			for _, e := range entries {
				m := partFileRe.FindStringSubmatch(e.Name())
				if len(m) != 2 {
					continue
				}
				seq, _ := strconv.Atoi(m[1])
				parts = append(parts, audioPart{
					Sequence:  seq,
					File:      filepath.Join(a.dir, e.Name()),
					OverlapMs: ovMap[seq],
				})
			}
			sort.Slice(parts, func(i, j int) bool { return parts[i].Sequence < parts[j].Sequence })
		}
		if len(parts) == 0 {
			_ = os.RemoveAll(a.dir)
			_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_recording_assemblies SET state='dropped', last_error='Recording assembly has no audio.', updated_at=? WHERE id=?`,
				timeutil.NowISO(), a.id)
			continue
		}

		dest := filepath.Join(s.pendingDir(), a.id+".wav")
		if err := concatRecording(s.cfg(), key, parts, dest); err != nil {
			_ = os.Remove(dest)
			s.RecordError(ctx, userID, err.Error())
			_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_recording_assemblies SET last_error=?, updated_at=? WHERE id=?`,
				err.Error(), timeutil.NowISO(), a.id)
			continue
		}
		st, _ := os.Stat(dest)
		sum, _ := fileSHA256(dest)
		_ = crypto.SealInPlace(key, dest)
		var capAt sql.NullString
		_ = s.DB.R.QueryRowContext(ctx, `SELECT device_started_at FROM recording_sessions WHERE id=?`, a.sessID).Scan(&capAt)
		_, _ = s.DB.W.ExecContext(ctx, `INSERT INTO cloud_archive_items
			(id, user_id, account_id, kind, local_path, remote_path, bytes, sha256, captured_at, state)
			VALUES (?, ?, ?, 'audio', ?, ?, ?, ?, ?, 'queued')`,
			uuid.NewString(), userID, a.accID, dest, a.remPath, st.Size(), sum, capAt)
		_ = os.RemoveAll(a.dir)
		_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM cloud_recording_assemblies WHERE id=?`, a.id)
		queued++
	}
	return queued
}

func (s *Service) Drain(ctx context.Context, userID string) (int, error) {
	s.finalizeReadyAssemblies(ctx, userID)
	key, err := s.MasterKey()
	if err != nil {
		return 0, err
	}
	uploaded := 0
	for {
		var id, accID, kind, remPath string
		var localPath, capAt, resUpID sql.NullString
		var attempts int
		err := s.DB.R.QueryRowContext(ctx, `SELECT id, account_id, kind, local_path, remote_path, captured_at, remote_upload_id, attempts
			FROM cloud_archive_items WHERE user_id=? AND state='queued' ORDER BY created_at ASC LIMIT 1`, userID).
			Scan(&id, &accID, &kind, &localPath, &remPath, &capAt, &resUpID, &attempts)
		if err == sql.ErrNoRows {
			break
		}
		if err != nil {
			return uploaded, err
		}
		if !localPath.Valid || localPath.String == "" {
			_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='dropped', last_error='Pending file is missing.', uploaded_at=? WHERE id=?`,
				timeutil.NowISO(), id)
			continue
		}
		if _, err := os.Stat(localPath.String); err != nil {
			_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='dropped', local_path=NULL, last_error='Pending file is missing.', uploaded_at=? WHERE id=?`,
				timeutil.NowISO(), id)
			continue
		}

		_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='uploading', attempts=attempts+1 WHERE id=?`, id)
		sink, sinkErr := s.sinkFor(ctx, userID)
		if sinkErr != nil {
			return uploaded, s.handlePutError(ctx, userID, id, localPath.String, attempts+1, sinkErr)
		}

		plainBytes, rerr := crypto.ReadSealedFile(key, localPath.String)
		if rerr != nil {
			return uploaded, s.handlePutError(ctx, userID, id, localPath.String, attempts+1, rerr)
		}
		tmpPlain, terr := os.CreateTemp(s.pendingDir(), "plain-up-*")
		if terr != nil {
			return uploaded, terr
		}
		tmpName := tmpPlain.Name()
		_, _ = tmpPlain.Write(plainBytes)
		_ = tmpPlain.Close()
		_ = os.Chmod(tmpName, 0o600)

		putErr := sink.Put(ctx, tmpName, remPath, PutOptions{
			CapturedAt:     capAt.String,
			ResumeUploadID: resUpID.String,
			OnUploadStarted: func(upID string) {
				var v any
				if upID != "" {
					v = upID
				}
				_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET remote_upload_id=? WHERE id=?`, v, id)
			},
		})
		_ = os.Remove(tmpName)
		if putErr != nil {
			return uploaded, s.handlePutError(ctx, userID, id, localPath.String, attempts+1, putErr)
		}

		_ = os.Remove(localPath.String)
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='uploaded', local_path=NULL, remote_upload_id=NULL, uploaded_at=?, last_error=NULL WHERE id=?`,
			timeutil.NowISO(), id)
		s.RecordSuccess(ctx, userID, kind)
		uploaded++
	}
	if uploaded > 0 {
		s.RefreshQuota(ctx, userID)
	}
	return uploaded, nil
}

func (s *Service) handlePutError(ctx context.Context, userID, itemID, localPath string, attempts int, putErr error) error {
	msg := putErr.Error()
	s.RecordError(ctx, userID, msg)
	if len(msg) > 500 {
		msg = msg[:500]
	}
	retryable := true
	var se *SinkError
	if errors.As(putErr, &se) {
		retryable = se.Retryable && se.Code != "CLOUD_AUTH_FAILED"
	}
	if !retryable || attempts >= s.cfg().CloudPutMaxAttempts {
		_ = os.Remove(localPath)
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='dropped', local_path=NULL, last_error=?, uploaded_at=? WHERE id=?`,
			msg, timeutil.NowISO(), itemID)
		if se != nil && se.Code == "CLOUD_AUTH_FAILED" {
			return putErr
		}
		return nil
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='queued', last_error=? WHERE id=?`, msg, itemID)
	return putErr
}

func (s *Service) RefreshQuota(ctx context.Context, userID string) {
	acc, secEnc, err := s.GetAccount(ctx, userID)
	if err != nil || acc == nil || acc.Type != "neocloud" || secEnc == "" {
		return
	}
	cred, err := s.decryptSecret(secEnc)
	if err != nil {
		return
	}
	sink := &neoCloudSink{baseURL: acc.BaseURL, token: cred, folder: acc.Folder, http: s.httpClient(), timeoutMs: s.cfg().CloudHTTPTimeoutMs}
	if info, err := sink.Me(ctx); err == nil {
		s.RecordQuota(ctx, userID, info.QuotaUsed, info.QuotaLimit)
	}
}

func (s *Service) BackupUserData(ctx context.Context, userID string, force bool) (int, error) {
	acc, _, err := s.GetAccount(ctx, userID)
	if err != nil {
		return 0, err
	}
	if acc == nil {
		return 0, httperr.New(404, "CLOUD_NOT_CONNECTED", "Connect a cloud backup first.")
	}
	if !force && !acc.DataBackupEnabled {
		return 0, nil
	}
	key, err := s.MasterKey()
	if err != nil {
		return 0, err
	}
	zipBytes, err := s.BuildUserExport(ctx, userID)
	if err != nil {
		return 0, err
	}
	dest := filepath.Join(s.pendingDir(), uuid.NewString()+".zip")
	if err := os.WriteFile(dest, zipBytes, 0o600); err != nil {
		return 0, err
	}
	sum := sha256.Sum256(zipBytes)
	sumHex := hex.EncodeToString(sum[:])
	if err := crypto.SealInPlace(key, dest); err != nil {
		_ = os.Remove(dest)
		return 0, err
	}
	remPath := fmt.Sprintf("backups/neorecall-user-%s.zip", time.Now().UTC().Format("20060102T150405Z"))
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO cloud_archive_items
		(id, user_id, account_id, kind, local_path, remote_path, bytes, sha256, state)
		VALUES (?, ?, ?, 'data', ?, ?, ?, ?, 'queued')`,
		uuid.NewString(), userID, acc.ID, dest, remPath, len(zipBytes), sumHex)
	if err != nil {
		return 0, err
	}
	s.EnqueuePut(ctx, userID)
	return s.Drain(ctx, userID)
}

func (s *Service) ScheduleDueBackups(ctx context.Context) int {
	users := s.ListDueDataBackups(ctx, max(1, s.cfg().CloudUserBackupIntervalHours))
	for _, u := range users {
		s.EnqueueDataBackup(ctx, u, "scheduled")
	}
	return len(users)
}

func (s *Service) EnqueuePendingPuts(ctx context.Context) {
	users := make(map[string]bool)
	rows1, _ := s.DB.R.QueryContext(ctx, `SELECT DISTINCT user_id FROM cloud_archive_items WHERE state='queued'`)
	if rows1 != nil {
		for rows1.Next() {
			var u string
			if rows1.Scan(&u) == nil {
				users[u] = true
			}
		}
		rows1.Close()
	}
	rows2, _ := s.DB.R.QueryContext(ctx, `SELECT DISTINCT a.user_id FROM cloud_recording_assemblies a
		LEFT JOIN recording_sessions s ON s.id=a.session_id
		WHERE a.state='assembling' AND (s.id IS NULL OR s.status != 'active')`)
	if rows2 != nil {
		for rows2.Next() {
			var u string
			if rows2.Scan(&u) == nil {
				users[u] = true
			}
		}
		rows2.Close()
	}
	for u := range users {
		s.EnqueuePut(ctx, u)
	}
}

func (s *Service) SweepPending(ctx context.Context) int {
	cutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -s.cfg().CloudPendingMaxAgeMs))
	oldCutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -24*60*60_000))
	removed := 0

	rows, _ := s.DB.R.QueryContext(ctx, `SELECT id, local_path FROM cloud_archive_items WHERE state IN ('queued','uploading','failed') AND created_at<?`, cutoff)
	if rows != nil {
		for rows.Next() {
			var id string
			var lp sql.NullString
			if rows.Scan(&id, &lp) == nil {
				if lp.Valid {
					_ = os.Remove(lp.String)
				}
				_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_archive_items SET state='dropped', local_path=NULL, last_error='Pending copy expired.', uploaded_at=? WHERE id=?`,
					timeutil.NowISO(), id)
				removed++
			}
		}
		rows.Close()
	}
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM cloud_archive_items WHERE state IN ('uploaded','dropped') AND created_at<?`, oldCutoff)

	arows, _ := s.DB.R.QueryContext(ctx, `SELECT a.id, a.local_dir FROM cloud_recording_assemblies a
		LEFT JOIN recording_sessions rs ON rs.id=a.session_id
		WHERE a.state='assembling' AND a.created_at<? AND (rs.id IS NULL OR rs.status != 'active')`, cutoff)
	if arows != nil {
		for arows.Next() {
			var id, dir string
			if arows.Scan(&id, &dir) == nil {
				_ = os.RemoveAll(dir)
				_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_recording_assemblies SET state='dropped', last_error='Pending recording copy expired.', updated_at=? WHERE id=?`,
					timeutil.NowISO(), id)
				removed++
			}
		}
		arows.Close()
	}
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM cloud_recording_assemblies WHERE state='dropped' AND updated_at<?`, oldCutoff)
	return removed
}

func (s *Service) DiscardPending(ctx context.Context, userID string) {
	rows1, _ := s.DB.R.QueryContext(ctx, `SELECT local_path FROM cloud_archive_items WHERE user_id=? AND local_path IS NOT NULL`, userID)
	if rows1 != nil {
		for rows1.Next() {
			var p string
			if rows1.Scan(&p) == nil && p != "" {
				_ = os.Remove(p)
			}
		}
		rows1.Close()
	}
	rows2, _ := s.DB.R.QueryContext(ctx, `SELECT local_dir FROM cloud_recording_assemblies WHERE user_id=?`, userID)
	if rows2 != nil {
		for rows2.Next() {
			var d string
			if rows2.Scan(&d) == nil && d != "" {
				_ = os.RemoveAll(d)
			}
		}
		rows2.Close()
	}
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
