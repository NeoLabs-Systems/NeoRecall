package jobs

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

type Job struct {
	ID               string
	UserID           string
	ResourceType     string
	ResourceID       string
	Type             string
	Status           string
	Priority         int
	Attempts         int
	MaxAttempts      int
	NextAttemptAt    string
	LeaseOwner       string
	LeaseExpiresAt   string
	PayloadJSON      string
	Payload          map[string]any
	LastErrorCode    string
	LastErrorMessage string
	CreatedAt        string
	UpdatedAt        string
	StartedAt        string
	CompletedAt      string
}

type EnqueueInput struct {
	UserID       string
	ResourceType string
	ResourceID   string
	Type         string
	Priority     int
	Payload      any
	MaxAttempts  int
}

type Service struct {
	DB  *dbx.DB
	Cfg func() config.Config
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func nullStr(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

func (s *Service) Enqueue(ctx context.Context, in EnqueueInput) (string, error) {
	return EnqueueTx(ctx, s.DB.W, in, s.cfg().JobMaxAttempts)
}

type DBExecQueryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func EnqueueTx(ctx context.Context, db DBExecQueryer, in EnqueueInput, defaultMaxAttempts int) (string, error) {
	if in.MaxAttempts <= 0 {
		if defaultMaxAttempts > 0 {
			in.MaxAttempts = defaultMaxAttempts
		} else {
			in.MaxAttempts = 5
		}
	}
	payloadMap := in.Payload
	if payloadMap == nil {
		payloadMap = map[string]any{}
	}
	payloadB, err := json.Marshal(payloadMap)
	if err != nil {
		return "", err
	}
	id := uuid.NewString()
	_, err = db.ExecContext(ctx, `INSERT INTO jobs
		(id, user_id, resource_type, resource_id, type, status, priority, max_attempts, payload_json)
		VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?)`,
		id, nullStr(in.UserID), nullStr(in.ResourceType), nullStr(in.ResourceID), in.Type, in.Priority, in.MaxAttempts, string(payloadB))
	if err != nil {
		if in.ResourceID != "" && strings.Contains(err.Error(), "UNIQUE constraint failed") {
			var existingID string
			if qerr := db.QueryRowContext(ctx, `SELECT id FROM jobs WHERE type=? AND resource_id=? AND status IN ('queued','leased')`,
				in.Type, in.ResourceID).Scan(&existingID); qerr == nil {
				return existingID, nil
			}
		}
		return "", err
	}
	return id, nil
}

// ClaimNext leases the highest-priority eligible queued job, enforcing strict
// per-source chunk sequence order and expired-lease recovery.
func (s *Service) ClaimNext(ctx context.Context, workerID string, leaseMsOverride int64, canTranscribe bool) (*Job, error) {
	leaseMs := s.cfg().JobLeaseMs
	if leaseMsOverride > 0 {
		leaseMs = leaseMsOverride
	}
	if leaseMs <= 0 {
		leaseMs = 1_800_000
	}
	now := time.Now()
	nowISO := timeutil.FormatISO(now)
	expISO := timeutil.FormatISO(timeutil.AddMillis(now, leaseMs))

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
		next_attempt_at=?, updated_at=? WHERE status='leased' AND lease_expires_at < ?`,
		nowISO, nowISO, nowISO); err != nil {
		return nil, err
	}

	canTransInt := 0
	if canTranscribe {
		canTransInt = 1
	}

	var j Job
	var uid, rt, rid, lo, le, lec, lem, st, co sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT j.id, j.user_id, j.resource_type, j.resource_id, j.type, j.status,
		j.priority, j.attempts, j.max_attempts, j.next_attempt_at, j.lease_owner, j.lease_expires_at,
		j.payload_json, j.last_error_code, j.last_error_message, j.created_at, j.updated_at, j.started_at, j.completed_at
		FROM jobs j WHERE j.status='queued' AND j.next_attempt_at <= ?
		  AND (? OR j.type != 'transcribe_chunk')
		  AND (j.type != 'transcribe_chunk' OR EXISTS (
			SELECT 1 FROM audio_chunks current_chunk WHERE current_chunk.id=j.resource_id
			AND (current_chunk.state='persisted_cleanup_pending' OR current_chunk.sequence=0 OR EXISTS (
			  SELECT 1 FROM audio_chunks previous_chunk
			  WHERE previous_chunk.source_id=current_chunk.source_id
				AND previous_chunk.sequence=current_chunk.sequence-1
				AND previous_chunk.state IN ('transcribed','silent')
			) OR EXISTS (
			  SELECT 1 FROM recording_gaps gap
			  WHERE gap.source_id=current_chunk.source_id
				AND current_chunk.sequence-1 BETWEEN gap.start_sequence AND gap.end_sequence
			))
		  ))
		ORDER BY j.priority DESC, j.created_at ASC LIMIT 1`, nowISO, canTransInt).
		Scan(&j.ID, &uid, &rt, &rid, &j.Type, &j.Status, &j.Priority, &j.Attempts, &j.MaxAttempts, &j.NextAttemptAt,
			&lo, &le, &j.PayloadJSON, &lec, &lem, &j.CreatedAt, &j.UpdatedAt, &st, &co)
	if errors.Is(err, sql.ErrNoRows) {
		_ = tx.Commit()
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	res, err := tx.ExecContext(ctx, `UPDATE jobs SET status='leased', lease_owner=?, lease_expires_at=?,
		attempts=attempts+1, started_at=COALESCE(started_at, ?), updated_at=? WHERE id=? AND status='queued'`,
		workerID, expISO, nowISO, nowISO, j.ID)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return nil, nil
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	j.UserID = uid.String
	j.ResourceType = rt.String
	j.ResourceID = rid.String
	j.Status = "leased"
	j.LeaseOwner = workerID
	j.LeaseExpiresAt = expISO
	j.Attempts++
	j.LastErrorCode = lec.String
	j.LastErrorMessage = lem.String
	j.StartedAt = st.String
	if j.StartedAt == "" {
		j.StartedAt = nowISO
	}
	j.CompletedAt = co.String
	j.Payload = map[string]any{}
	_ = json.Unmarshal([]byte(j.PayloadJSON), &j.Payload)
	return &j, nil
}

func (s *Service) RenewLease(ctx context.Context, id, workerID string, leaseMsOverride int64) bool {
	leaseMs := s.cfg().JobLeaseMs
	if leaseMsOverride > 0 {
		leaseMs = leaseMsOverride
	}
	if leaseMs <= 0 {
		leaseMs = 1_800_000
	}
	now := time.Now()
	res, err := s.DB.W.ExecContext(ctx, `UPDATE jobs SET lease_expires_at=?, updated_at=? WHERE id=? AND status='leased' AND lease_owner=?`,
		timeutil.FormatISO(timeutil.AddMillis(now, leaseMs)), timeutil.FormatISO(now), id, workerID)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

func (s *Service) Complete(ctx context.Context, id, workerID string) bool {
	nowISO := timeutil.NowISO()
	res, err := s.DB.W.ExecContext(ctx, `UPDATE jobs SET status='completed', lease_owner=NULL, lease_expires_at=NULL,
		completed_at=?, updated_at=? WHERE id=? AND status='leased' AND lease_owner=?`, nowISO, nowISO, id, workerID)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

func (s *Service) Fail(ctx context.Context, id, workerID, errCode, errMsg string, retryable bool) (willRetry bool) {
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return false
	}
	defer tx.Rollback()

	var attempts, maxAttempts int
	err = tx.QueryRowContext(ctx, `SELECT attempts, max_attempts FROM jobs WHERE id=? AND status='leased' AND lease_owner=?`, id, workerID).
		Scan(&attempts, &maxAttempts)
	if err != nil {
		return false
	}
	shouldRetry := retryable && attempts < maxAttempts
	c := s.cfg()
	baseMs := c.JobRetryBaseMs
	if baseMs <= 0 {
		baseMs = 5_000
	}
	maxMs := c.JobRetryMaxMs
	if maxMs <= 0 {
		maxMs = 15 * 60_000
	}
	expFactor := math.Pow(2, float64(max(0, attempts-1)))
	delayMs := min(maxMs, int64(expFactor*float64(baseMs)))

	status := "failed"
	var compAt sql.NullString
	now := time.Now()
	nowISO := timeutil.FormatISO(now)
	if shouldRetry {
		status = "queued"
	} else {
		compAt = sql.NullString{String: nowISO, Valid: true}
	}
	if errCode == "" {
		errCode = "JOB_FAILED"
	}
	if len(errMsg) > 1000 {
		errMsg = errMsg[:1000]
	}
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status=?, lease_owner=NULL, lease_expires_at=NULL, next_attempt_at=?,
		last_error_code=?, last_error_message=?, completed_at=?, updated_at=? WHERE id=?`,
		status, timeutil.FormatISO(timeutil.AddMillis(now, delayMs)), errCode, errMsg, compAt, nowISO, id); err != nil {
		return false
	}
	return tx.Commit() == nil && shouldRetry
}

// Defer returns a leased job back to queued without burning attempts (e.g. rolling quota pause).
func (s *Service) Defer(ctx context.Context, id, workerID, nextAttemptAt string) bool {
	when := timeutil.FormatISO(time.Now().Add(time.Minute))
	if t, err := timeutil.ParseISO(nextAttemptAt); err == nil {
		when = timeutil.FormatISO(t)
	}
	nowISO := timeutil.NowISO()
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return false
	}
	defer tx.Rollback()
	var dummy int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM jobs WHERE id=? AND status='leased' AND lease_owner=?`, id, workerID).Scan(&dummy); err != nil {
		return false
	}
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status='queued', lease_owner=NULL, lease_expires_at=NULL,
		attempts=MAX(0, attempts-1), next_attempt_at=?, last_error_code='USAGE_LIMIT_EXCEEDED',
		last_error_message='Waiting for the account usage window to open.', completed_at=NULL, updated_at=? WHERE id=?`,
		when, nowISO, id); err != nil {
		return false
	}
	return tx.Commit() == nil
}

func (s *Service) Retry(ctx context.Context, id string) bool {
	nowISO := timeutil.NowISO()
	res, err := s.DB.W.ExecContext(ctx, `UPDATE jobs SET status='queued', attempts=0, next_attempt_at=?, lease_owner=NULL,
		lease_expires_at=NULL, last_error_code=NULL, last_error_message=NULL, completed_at=NULL, updated_at=?
		WHERE id=? AND status='failed'`, nowISO, nowISO, id)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}

func (s *Service) Cancel(ctx context.Context, id string) bool {
	nowISO := timeutil.NowISO()
	res, err := s.DB.W.ExecContext(ctx, `UPDATE jobs SET status='cancelled', completed_at=?, updated_at=? WHERE id=? AND status IN ('queued','failed')`,
		nowISO, nowISO, id)
	if err != nil {
		return false
	}
	n, _ := res.RowsAffected()
	return n == 1
}
