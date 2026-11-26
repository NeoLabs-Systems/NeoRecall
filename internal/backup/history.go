package backup

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

// RunResult is what one requested backup did.
type RunResult struct {
	ID       string `json:"id,omitempty"`
	Key      string `json:"key,omitempty"`
	Bytes    int64  `json:"bytes,omitempty"`
	Checksum string `json:"checksum,omitempty"`
	Pruned   int    `json:"pruned"`
	Skipped  bool   `json:"skipped,omitempty"`
	Reason   string `json:"reason,omitempty"`
}

// Record is one row of the backup history the admin page lists.
type Record struct {
	ID           string  `json:"id"`
	Destination  string  `json:"destination"`
	ArtifactKey  *string `json:"artifact_key"`
	Bytes        *int64  `json:"bytes"`
	Checksum     *string `json:"checksum"`
	TriggerKind  string  `json:"trigger_kind"`
	State        string  `json:"state"`
	ErrorCode    *string `json:"error_code"`
	ErrorMessage *string `json:"error_message"`
	StartedAt    string  `json:"started_at"`
	CompletedAt  *string `json:"completed_at"`
	PrunedAt     *string `json:"pruned_at"`
}

// Run takes a backup and records it. triggerKind is "manual" or "scheduled". A
// caller arriving while one is in flight is told so rather than queued.
func (s *Service) Run(ctx context.Context, triggerKind string) (RunResult, error) {
	if !s.running.TryLock() {
		return RunResult{Skipped: true, Reason: "already_running"}, nil
	}
	defer s.running.Unlock()
	dst, err := s.Destination()
	if err != nil {
		return RunResult{}, err
	}
	id := uuid.NewString()
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO backups (id, destination, trigger_kind, state) VALUES (?, ?, ?, 'running')`,
		id, dst.Name(), triggerKind); err != nil {
		return RunResult{}, err
	}
	art, checksum, pruned, err := s.create(ctx, dst)
	if err != nil {
		message := err.Error()
		_, recordErr := s.DB.W.ExecContext(context.WithoutCancel(ctx), `UPDATE backups SET state='failed', error_code='BACKUP_FAILED',
			error_message=?, completed_at=? WHERE id=?`, message[:min(500, len(message))], timeutil.NowISO(), id)
		return RunResult{}, errors.Join(err, recordErr)
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE backups SET state='succeeded', artifact_key=?, bytes=?, checksum=?, completed_at=? WHERE id=?`,
		art.Key, art.Bytes, checksum, timeutil.NowISO(), id); err != nil {
		return RunResult{}, err
	}
	for _, key := range pruned {
		if _, err := s.DB.W.ExecContext(ctx, `UPDATE backups SET pruned_at=? WHERE artifact_key=? AND pruned_at IS NULL`,
			timeutil.NowISO(), key); err != nil {
			return RunResult{}, err
		}
	}
	return RunResult{ID: id, Key: art.Key, Bytes: art.Bytes, Checksum: checksum, Pruned: len(pruned)}, nil
}

// History returns recorded runs, newest first.
func (s *Service) History(ctx context.Context, limit int) ([]Record, error) {
	return s.records(ctx, `ORDER BY started_at DESC LIMIT ?`, min(100, max(1, limit)))
}

func (s *Service) records(ctx context.Context, clause string, args ...any) ([]Record, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, destination, artifact_key, bytes, checksum, trigger_kind, state,
		error_code, error_message, started_at, completed_at, pruned_at FROM backups `+clause, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Record{}
	for rows.Next() {
		var r Record
		if err := rows.Scan(&r.ID, &r.Destination, &r.ArtifactKey, &r.Bytes, &r.Checksum, &r.TriggerKind, &r.State,
			&r.ErrorCode, &r.ErrorMessage, &r.StartedAt, &r.CompletedAt, &r.PrunedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Overview is the backup status the admin page shows above the history.
func (s *Service) Overview(ctx context.Context) (map[string]any, error) {
	c := s.cfg()
	last, err := s.records(ctx, `ORDER BY started_at DESC LIMIT 1`)
	if err != nil {
		return nil, err
	}
	var succeededAt sql.NullString
	err = s.DB.R.QueryRowContext(ctx, `SELECT completed_at FROM backups WHERE state='succeeded' ORDER BY completed_at DESC LIMIT 1`).Scan(&succeededAt)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	out := map[string]any{
		"enabled": c.BackupEnabled, "destination": c.BackupDestination, "location": nil, "unreachable": nil,
		"intervalHours": c.BackupIntervalHours, "retain": c.BackupRetain,
		"due": c.BackupEnabled, "nextDueAt": nil, "last": nil, "lastSuccessAt": nil,
	}
	if s.running.TryLock() {
		s.running.Unlock()
		out["running"] = false
	} else {
		out["running"] = true
	}
	if len(last) > 0 {
		out["last"] = last[0]
	}
	if succeeded, err := timeutil.ParseISO(succeededAt.String); err == nil && succeededAt.Valid {
		next := succeeded.Add(time.Duration(c.BackupIntervalHours) * time.Hour)
		out["lastSuccessAt"] = succeededAt.String
		out["nextDueAt"] = timeutil.FormatISO(next)
		out["due"] = c.BackupEnabled && !time.Now().Before(next)
	}
	artifacts := []Artifact{}
	dst, err := s.Destination()
	if err == nil {
		out["location"] = dst.Describe()
		artifacts, err = dst.List()
	}
	if err != nil {
		out["unreachable"] = err.Error()
	}
	var total int64
	for _, artifact := range artifacts {
		total += artifact.Bytes
	}
	out["artifactCount"] = len(artifacts)
	out["artifactBytes"] = total
	out["artifacts"] = artifacts[:min(20, len(artifacts))]
	return out, nil
}
