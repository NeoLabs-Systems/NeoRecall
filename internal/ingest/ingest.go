package ingest

import (
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"os"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

type Service struct {
	DB           *dbx.DB
	Cfg          func() config.Config
	MasterKey    func() ([]byte, error)
	TempAudio    *TempAudio
	Receipts     *Receipts
	FinalizeSess func(ctx context.Context, sessionID string)
	ReconcileImp func(ctx context.Context)
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

type SessionRow struct {
	ID                   string  `json:"id"`
	UserID               string  `json:"user_id"`
	DeviceID             string  `json:"device_id"`
	ClientUUID           string  `json:"client_uuid"`
	DeviceStartedAt      string  `json:"device_started_at"`
	CorrectedStartedAt   string  `json:"corrected_started_at"`
	DeviceEndedAt        *string `json:"device_ended_at"`
	CorrectedEndedAt     *string `json:"corrected_ended_at"`
	Timezone             string  `json:"timezone"`
	InitialClockOffsetMs int64   `json:"initial_clock_offset_ms"`
	ConsentAttestedAt    string  `json:"consent_attested_at"`
	Status               string  `json:"status"`
	CreatedAt            string  `json:"created_at"`
	UpdatedAt            string  `json:"updated_at"`
}

type SourceInput struct {
	ID            string         `json:"id"`
	ClientUUID    string         `json:"clientUuid"`
	Kind          string         `json:"kind"`
	ChannelLayout string         `json:"channelLayout"`
	SampleRate    int            `json:"sampleRate"`
	SampleFormat  string         `json:"sampleFormat"`
	Metadata      map[string]any `json:"metadata"`
}

type SourceRow struct {
	ID                    string  `json:"id"`
	SessionID             string  `json:"session_id"`
	ClientUUID            string  `json:"client_uuid"`
	Kind                  string  `json:"kind"`
	ChannelLayout         string  `json:"channel_layout"`
	SampleRate            int     `json:"sample_rate"`
	SampleFormat          string  `json:"sample_format"`
	MetadataJSON          string  `json:"metadata_json"`
	FinalSequence         *int    `json:"final_sequence"`
	ClosedAt              *string `json:"closed_at"`
	ContiguousTerminalSeq *int    `json:"contiguous_terminal_sequence"`
	CreatedAt             string  `json:"created_at"`
}

func scanSession(q interface{ Scan(...any) error }) (SessionRow, error) {
	var r SessionRow
	var de, ce sql.NullString
	var off sql.NullFloat64
	err := q.Scan(&r.ID, &r.UserID, &r.DeviceID, &r.ClientUUID, &r.DeviceStartedAt, &r.CorrectedStartedAt,
		&de, &ce, &r.Timezone, &off, &r.ConsentAttestedAt, &r.Status, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return SessionRow{}, err
	}
	if off.Valid {
		r.InitialClockOffsetMs = int64(math.Round(off.Float64))
	}
	if de.Valid {
		v := de.String
		r.DeviceEndedAt = &v
	}
	if ce.Valid {
		v := ce.String
		r.CorrectedEndedAt = &v
	}
	return r, nil
}

const sessCols = `id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, device_ended_at, corrected_ended_at, timezone, initial_clock_offset_ms, consent_attested_at, status, created_at, updated_at`

func scanSource(q interface{ Scan(...any) error }) (SourceRow, error) {
	var sr SourceRow
	var fs, cts sql.NullInt64
	var ca sql.NullString
	err := q.Scan(&sr.ID, &sr.SessionID, &sr.ClientUUID, &sr.Kind, &sr.ChannelLayout, &sr.SampleRate,
		&sr.SampleFormat, &sr.MetadataJSON, &fs, &ca, &cts, &sr.CreatedAt)
	if err != nil {
		return SourceRow{}, err
	}
	if fs.Valid {
		v := int(fs.Int64)
		sr.FinalSequence = &v
	}
	if ca.Valid {
		v := ca.String
		sr.ClosedAt = &v
	}
	if cts.Valid {
		v := int(cts.Int64)
		sr.ContiguousTerminalSeq = &v
	}
	return sr, nil
}

const srcCols = `id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format, metadata_json, final_sequence, closed_at, contiguous_terminal_sequence, created_at`

func (s *Service) ownedSession(ctx context.Context, userID, sessionID string) (SessionRow, error) {
	sr, err := scanSession(s.DB.R.QueryRowContext(ctx, `SELECT `+sessCols+` FROM recording_sessions WHERE id=? AND user_id=?`, sessionID, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return SessionRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Recording session not found.")
	}
	return sr, err
}

func (s *Service) ownedSource(ctx context.Context, userID, sessionID, sourceID string) (SourceRow, error) {
	sr, err := scanSource(s.DB.R.QueryRowContext(ctx, `SELECT `+stringsReplacePrefix(srcCols, "s.")+` FROM recording_sources s JOIN recording_sessions r ON r.id=s.session_id
		WHERE s.id=? AND s.session_id=? AND r.user_id=?`, sourceID, sessionID, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return SourceRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Recording source not found.")
	}
	return sr, err
}

func stringsReplacePrefix(cols, prefix string) string {
	// Prepend alias to comma-separated columns cleanly.
	out := make([]byte, 0, len(cols)+len(prefix)*12)
	out = append(out, prefix...)
	for i := 0; i < len(cols); i++ {
		out = append(out, cols[i])
		if cols[i] == ',' && i+1 < len(cols) && cols[i+1] == ' ' {
			out = append(out, ' ')
			out = append(out, prefix...)
			i++
		}
	}
	return string(out)
}

func correctedTime(deviceISO string, offsetMs int64) (string, error) {
	t, err := timeutil.ParseISO(deviceISO)
	if err != nil {
		return "", httperr.New(http.StatusBadRequest, "INVALID_TIMESTAMP", "A device timestamp is invalid.")
	}
	return timeutil.FormatISO(timeutil.AddMillis(t, -offsetMs)), nil
}

type CreateSessionInput struct {
	ID                string
	DeviceID          string
	ClientUUID        string
	StartedAt         string
	Timezone          string
	ClockOffsetMs     *int64
	ConsentAttestedAt string
	Sources           []SourceInput
}

func (s *Service) CreateSession(ctx context.Context, userID string, in CreateSessionInput) (SessionRow, []SourceRow, error) {
	var devOffset sql.NullFloat64
	err := s.DB.R.QueryRowContext(ctx, `SELECT clock_offset_ms FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL`, in.DeviceID, userID).Scan(&devOffset)
	if errors.Is(err, sql.ErrNoRows) {
		return SessionRow{}, nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Device not found.")
	}
	if err != nil {
		return SessionRow{}, nil, err
	}

	existing, err := scanSession(s.DB.R.QueryRowContext(ctx, `SELECT `+sessCols+` FROM recording_sessions WHERE user_id=? AND client_uuid=?`, userID, in.ClientUUID))
	if err == nil {
		srcs, err := s.listSources(ctx, existing.ID)
		return existing, srcs, err
	} else if !errors.Is(err, sql.ErrNoRows) {
		return SessionRow{}, nil, err
	}

	id := in.ID
	if id == "" {
		id = uuid.NewString()
	}
	var offset int64
	if devOffset.Valid {
		offset = int64(math.Round(devOffset.Float64))
	}
	if in.ClockOffsetMs != nil {
		offset = *in.ClockOffsetMs
	}
	corrStart, err := correctedTime(in.StartedAt, offset)
	if err != nil {
		return SessionRow{}, nil, err
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return SessionRow{}, nil, err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `INSERT INTO recording_sessions
		(id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, initial_clock_offset_ms, consent_attested_at, status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')`,
		id, userID, in.DeviceID, in.ClientUUID, in.StartedAt, corrStart, in.Timezone, offset, in.ConsentAttestedAt); err != nil {
		return SessionRow{}, nil, err
	}
	for _, src := range in.Sources {
		sid := src.ID
		if sid == "" {
			sid = uuid.NewString()
		}
		meta := src.Metadata
		if meta == nil {
			meta = map[string]any{}
		}
		metaB, _ := json.Marshal(meta)
		if _, err := tx.ExecContext(ctx, `INSERT INTO recording_sources
			(id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format, metadata_json)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			sid, id, src.ClientUUID, src.Kind, src.ChannelLayout, src.SampleRate, src.SampleFormat, string(metaB)); err != nil {
			return SessionRow{}, nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return SessionRow{}, nil, err
	}
	sess, err := s.ownedSession(ctx, userID, id)
	if err != nil {
		return SessionRow{}, nil, err
	}
	srcs, err := s.listSources(ctx, id)
	return sess, srcs, err
}

func (s *Service) listSources(ctx context.Context, sessionID string) ([]SourceRow, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+srcCols+` FROM recording_sources WHERE session_id=? ORDER BY created_at`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SourceRow{}
	for rows.Next() {
		sr, err := scanSource(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sr)
	}
	return out, rows.Err()
}

func (s *Service) AddSource(ctx context.Context, userID, sessionID string, in SourceInput) (SourceRow, error) {
	sess, err := s.ownedSession(ctx, userID, sessionID)
	if err != nil {
		return SourceRow{}, err
	}
	if sess.Status != "active" {
		return SourceRow{}, httperr.New(http.StatusConflict, "SESSION_CLOSED", "The recording session is closed.")
	}
	existing, err := scanSource(s.DB.R.QueryRowContext(ctx, `SELECT `+srcCols+` FROM recording_sources WHERE session_id=? AND client_uuid=?`, sessionID, in.ClientUUID))
	if err == nil {
		return existing, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return SourceRow{}, err
	}
	sid := in.ID
	if sid == "" {
		sid = uuid.NewString()
	}
	meta := in.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	metaB, _ := json.Marshal(meta)
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO recording_sources
		(id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format, metadata_json)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		sid, sessionID, in.ClientUUID, in.Kind, in.ChannelLayout, in.SampleRate, in.SampleFormat, string(metaB)); err != nil {
		return SourceRow{}, err
	}
	return s.ownedSource(ctx, userID, sessionID, sid)
}

func (s *Service) CloseSource(ctx context.Context, userID, sessionID, sourceID string, finalSequence int) (SyncState, error) {
	if _, err := s.ownedSource(ctx, userID, sessionID, sourceID); err != nil {
		return SyncState{}, err
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE recording_sources SET final_sequence=?, closed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
		finalSequence, sourceID); err != nil {
		return SyncState{}, err
	}
	return s.SyncState(ctx, userID, sessionID)
}

type CloseSourceSpec struct {
	ID            string `json:"id"`
	FinalSequence int    `json:"finalSequence"`
}

func (s *Service) CloseSession(ctx context.Context, userID, sessionID, endedAt, status string, sources []CloseSourceSpec) (SessionRow, error) {
	sess, err := s.ownedSession(ctx, userID, sessionID)
	if err != nil {
		return SessionRow{}, err
	}
	if status == "" {
		status = "ended"
	}
	corrEnd, err := correctedTime(endedAt, sess.InitialClockOffsetMs)
	if err != nil {
		return SessionRow{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return SessionRow{}, err
	}
	defer tx.Rollback()
	for _, src := range sources {
		if _, err := s.ownedSource(ctx, userID, sessionID, src.ID); err != nil {
			return SessionRow{}, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE recording_sources SET final_sequence=?, closed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
			src.FinalSequence, src.ID); err != nil {
			return SessionRow{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE recording_sessions SET device_ended_at=?, corrected_ended_at=?, status=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, endedAt, corrEnd, status, sessionID); err != nil {
		return SessionRow{}, err
	}
	if err := tx.Commit(); err != nil {
		return SessionRow{}, err
	}
	if s.FinalizeSess != nil {
		s.FinalizeSess(ctx, sessionID)
	}
	return s.ownedSession(ctx, userID, sessionID)
}

type GapInput struct {
	ID            string `json:"id"`
	SourceID      string `json:"sourceId"`
	StartOffsetMs int    `json:"startOffsetMs"`
	EndOffsetMs   int    `json:"endOffsetMs"`
	StartSequence *int   `json:"startSequence"`
	EndSequence   *int   `json:"endSequence"`
	Reason        string `json:"reason"`
}

func (s *Service) AddGaps(ctx context.Context, userID, sessionID string, gaps []GapInput) error {
	if _, err := s.ownedSession(ctx, userID, sessionID); err != nil {
		return err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, g := range gaps {
		if _, err := s.ownedSource(ctx, userID, sessionID, g.SourceID); err != nil {
			return err
		}
		gid := g.ID
		if gid == "" {
			gid = uuid.NewString()
		}
		var ss, es sql.NullInt64
		if g.StartSequence != nil {
			ss = sql.NullInt64{Int64: int64(*g.StartSequence), Valid: true}
		}
		if g.EndSequence != nil {
			es = sql.NullInt64{Int64: int64(*g.EndSequence), Valid: true}
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO recording_gaps
			(id, session_id, source_id, start_offset_ms, end_offset_ms, start_sequence, end_sequence, reason)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			gid, sessionID, g.SourceID, g.StartOffsetMs, g.EndOffsetMs, ss, es, g.Reason); err != nil {
			return err
		}
	}
	return tx.Commit()
}

type ChunkInput struct {
	IdempotencyKey    string
	SHA256            string
	DurationMs        int
	OverlapMs         int
	ChannelLayout     string
	MonotonicOffsetMs int64
	DeviceStartedAt   string
	Container         string
	Codec             string
	ContentEncoding   string
	IsFinal           bool
}

func restoreUploadedGzip(filePath string, contentEncoding string, maxBytes int64) (int64, error) {
	st, err := os.Stat(filePath)
	if err != nil {
		return 0, err
	}
	if contentEncoding != "gzip" {
		return st.Size(), nil
	}
	restoredPath := filePath + ".restored"
	in, err := os.Open(filePath)
	if err != nil {
		return 0, err
	}
	defer in.Close()

	gz, err := gzip.NewReader(in)
	if err != nil {
		return 0, httperr.New(http.StatusBadRequest, "INVALID_AUDIO_ENCODING", "The gzip audio payload is invalid.")
	}
	defer gz.Close()

	out, err := os.OpenFile(restoredPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return 0, err
	}
	n, copyErr := io.Copy(out, io.LimitReader(gz, maxBytes+1))
	cerr := out.Close()
	if copyErr != nil || cerr != nil {
		_ = os.Remove(restoredPath)
		return 0, httperr.New(http.StatusBadRequest, "INVALID_AUDIO_ENCODING", "The gzip audio payload is invalid.")
	}
	if n > maxBytes {
		_ = os.Remove(restoredPath)
		return 0, httperr.New(http.StatusRequestEntityTooLarge, "AUDIO_TOO_LARGE", "The restored audio exceeds the upload limit.")
	}
	in.Close()
	gz.Close()
	if err := os.Rename(restoredPath, filePath); err != nil {
		_ = os.Remove(restoredPath)
		return 0, err
	}
	return n, nil
}

func (s *Service) AcceptChunk(ctx context.Context, userID, sessionID, sourceID string, sequence int, in ChunkInput, tempUploadPath string) (Receipt, error) {
	if tempUploadPath == "" {
		return Receipt{}, httperr.New(http.StatusBadRequest, "AUDIO_REQUIRED", "The audio field is required.")
	}
	defer func() {
		_ = UnlinkStrict(tempUploadPath)
	}()

	src, err := s.ownedSource(ctx, userID, sessionID, sourceID)
	if err != nil {
		return Receipt{}, err
	}
	if src.ClosedAt != nil && src.FinalSequence != nil && sequence > *src.FinalSequence {
		return Receipt{}, httperr.New(http.StatusConflict, "SOURCE_CLOSED", "The sequence is beyond the closed source.")
	}
	c := s.cfg()
	byteSize, err := restoreUploadedGzip(tempUploadPath, in.ContentEncoding, c.MaxUploadBytes)
	if err != nil {
		return Receipt{}, err
	}
	minDur := c.ChunkMinMs
	if in.IsFinal {
		minDur = 1
	}
	if in.DurationMs > c.ChunkMaxMs || in.DurationMs < minDur {
		return Receipt{}, httperr.New(http.StatusBadRequest, "INVALID_DURATION", "Chunk duration is outside the configured range.")
	}
	actualHash, err := crypto.SHA256File(tempUploadPath)
	if err != nil {
		return Receipt{}, err
	}
	if actualHash != in.SHA256 {
		return Receipt{}, httperr.New(http.StatusUnprocessableEntity, "HASH_MISMATCH", "The uploaded audio does not match X-Chunk-Sha256.")
	}

	var existing *chunkRow
	if r1, err := scanChunk(s.DB.R.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE source_id=? AND sequence=?`, sourceID, sequence)); err == nil {
		existing = &r1
	} else if r2, err := scanChunk(s.DB.R.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE user_id=? AND idempotency_key=?`, userID, in.IdempotencyKey)); err == nil {
		existing = &r2
	}

	key, err := s.MasterKey()
	if err != nil {
		return Receipt{}, err
	}

	if existing != nil {
		if existing.SourceID != sourceID || existing.Sequence != sequence || existing.IdempotencyKey != in.IdempotencyKey ||
			existing.SHA256 != actualHash || existing.ByteSize != byteSize || existing.DurationMs != in.DurationMs ||
			existing.OverlapMs != in.OverlapMs || existing.ChannelLayout != in.ChannelLayout || existing.MonotonicOffsetMs != in.MonotonicOffsetMs {
			return Receipt{}, httperr.New(http.StatusConflict, "IDEMPOTENCY_CONFLICT", "This sequence or idempotency key was already used with different content or metadata.")
		}
		if existing.State != "reupload_required" {
			rec := formatReceipt(*existing, s.Receipts.ProcessingEstimateContext(ctx))
			rec.Duplicate = true
			return rec, nil
		}
		dest := s.TempAudio.ChunkPath(existing.ID, in.Container)
		if err := os.Rename(tempUploadPath, dest); err != nil {
			return Receipt{}, err
		}
		if err := crypto.SealInPlace(key, dest); err != nil {
			_ = UnlinkStrict(dest)
			return Receipt{}, err
		}
		tx, err := s.DB.W.BeginTx(ctx, nil)
		if err != nil {
			_ = UnlinkStrict(dest)
			return Receipt{}, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE audio_chunks SET temporary_path=?, state='uploaded', error_code=NULL, error_message=NULL,
			uploaded_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`,
			dest, existing.ID); err != nil {
			tx.Rollback()
			_ = UnlinkStrict(dest)
			return Receipt{}, err
		}
		if _, err := jobs.EnqueueTx(ctx, tx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "audio_chunk", ResourceID: existing.ID, Type: "transcribe_chunk", Priority: 100,
		}, c.JobMaxAttempts); err != nil {
			tx.Rollback()
			_ = UnlinkStrict(dest)
			return Receipt{}, err
		}
		if err := tx.Commit(); err != nil {
			_ = UnlinkStrict(dest)
			return Receipt{}, err
		}
		rec, err := s.Receipts.FindForUser(ctx, userID, existing.ID)
		if err != nil || rec == nil {
			return Receipt{}, err
		}
		return *rec, nil
	}

	id := uuid.NewString()
	dest := s.TempAudio.ChunkPath(id, in.Container)
	if err := os.Rename(tempUploadPath, dest); err != nil {
		return Receipt{}, err
	}
	if err := crypto.SealInPlace(key, dest); err != nil {
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO audio_chunks
		(id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout,
		 device_started_at, monotonic_offset_ms, duration_ms, overlap_ms, state, temporary_path)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'uploaded', ?)`,
		id, userID, sessionID, sourceID, sequence, in.IdempotencyKey, actualHash, byteSize,
		in.Container, in.Codec, in.ChannelLayout, in.DeviceStartedAt, in.MonotonicOffsetMs, in.DurationMs, in.OverlapMs, dest); err != nil {
		tx.Rollback()
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	if _, err := jobs.EnqueueTx(ctx, tx, jobs.EnqueueInput{
		UserID: userID, ResourceType: "audio_chunk", ResourceID: id, Type: "transcribe_chunk", Priority: 100,
	}, c.JobMaxAttempts); err != nil {
		tx.Rollback()
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	if err := events.EmitExec(ctx, tx, userID, "chunk.uploaded", "audio_chunk", id, map[string]any{
		"chunkId": id, "sourceId": sourceID, "sequence": sequence, "state": "uploaded",
	}); err != nil {
		tx.Rollback()
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	if err := tx.Commit(); err != nil {
		_ = UnlinkStrict(dest)
		return Receipt{}, err
	}
	rec, err := s.Receipts.FindForUser(ctx, userID, id)
	if err != nil || rec == nil {
		return Receipt{}, err
	}
	return *rec, nil
}

func (s *Service) Status(ctx context.Context, userID string, chunkIDs []string) ([]Receipt, error) {
	est := s.Receipts.ProcessingEstimateContext(ctx)
	out := make([]Receipt, 0, len(chunkIDs))
	for _, cid := range chunkIDs {
		row, err := scanChunk(s.DB.R.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE id=? AND user_id=?`, cid, userID))
		if err != nil {
			continue
		}
		out = append(out, formatReceipt(row, est))
	}
	return out, nil
}

func (s *Service) Released(ctx context.Context, userID string, chunkIDs []string) (int, error) {
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	count := 0
	for _, cid := range chunkIDs {
		res, err := tx.ExecContext(ctx, `UPDATE audio_chunks SET
			client_released_at=COALESCE(client_released_at, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
			WHERE id=? AND user_id=? AND state IN ('transcribed','silent')`, cid, userID)
		if err != nil {
			return 0, err
		}
		n, _ := res.RowsAffected()
		count += int(n)
	}
	return count, tx.Commit()
}

type MissingRange struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

type SyncGap struct {
	ID            string `json:"id"`
	StartOffsetMs int    `json:"start_offset_ms"`
	EndOffsetMs   int    `json:"end_offset_ms"`
	StartSequence *int   `json:"start_sequence"`
	EndSequence   *int   `json:"end_sequence"`
	Reason        string `json:"reason"`
}

type SyncSourceState struct {
	SourceID      string         `json:"sourceId"`
	FinalSequence *int           `json:"finalSequence"`
	MissingRanges []MissingRange `json:"missingRanges"`
	Gaps          []SyncGap      `json:"gaps"`
	Receipts      []Receipt      `json:"receipts"`
}

type SyncState struct {
	SessionID string            `json:"sessionId"`
	Sources   []SyncSourceState `json:"sources"`
}

func missingRanges(seqs []int, finalSeq *int, gaps []SyncGap) []MissingRange {
	if finalSeq == nil {
		return []MissingRange{}
	}
	known := map[int]bool{}
	for _, sq := range seqs {
		known[sq] = true
	}
	for _, g := range gaps {
		if g.StartSequence == nil || g.EndSequence == nil {
			continue
		}
		for seq := *g.StartSequence; seq <= *g.EndSequence; seq++ {
			known[seq] = true
		}
	}
	ranges := []MissingRange{}
	start := -1
	for i := 0; i <= *finalSeq; i++ {
		if !known[i] && start == -1 {
			start = i
		}
		if (known[i] || i == *finalSeq) && start != -1 {
			end := i
			if known[i] {
				end = i - 1
			}
			ranges = append(ranges, MissingRange{Start: start, End: end})
			start = -1
		}
	}
	return ranges
}

func (s *Service) SyncState(ctx context.Context, userID, sessionID string) (SyncState, error) {
	if _, err := s.ownedSession(ctx, userID, sessionID); err != nil {
		return SyncState{}, err
	}
	sources, err := s.listSources(ctx, sessionID)
	if err != nil {
		return SyncState{}, err
	}
	est := s.Receipts.ProcessingEstimateContext(ctx)
	out := SyncState{SessionID: sessionID, Sources: make([]SyncSourceState, 0, len(sources))}
	for _, src := range sources {
		rows, err := s.DB.R.QueryContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE source_id=? ORDER BY sequence`, src.ID)
		if err != nil {
			return SyncState{}, err
		}
		var seqs []int
		receipts := []Receipt{}
		for rows.Next() {
			ch, err := scanChunk(rows)
			if err != nil {
				rows.Close()
				return SyncState{}, err
			}
			seqs = append(seqs, ch.Sequence)
			receipts = append(receipts, formatReceipt(ch, est))
		}
		rows.Close()

		gapRows, err := s.DB.R.QueryContext(ctx, `SELECT id, start_offset_ms, end_offset_ms, start_sequence, end_sequence, reason
			FROM recording_gaps WHERE source_id=? ORDER BY start_offset_ms`, src.ID)
		if err != nil {
			return SyncState{}, err
		}
		gaps := []SyncGap{}
		for gapRows.Next() {
			var g SyncGap
			var ss, es sql.NullInt64
			if err := gapRows.Scan(&g.ID, &g.StartOffsetMs, &g.EndOffsetMs, &ss, &es, &g.Reason); err != nil {
				gapRows.Close()
				return SyncState{}, err
			}
			if ss.Valid {
				v := int(ss.Int64)
				g.StartSequence = &v
			}
			if es.Valid {
				v := int(es.Int64)
				g.EndSequence = &v
			}
			gaps = append(gaps, g)
		}
		gapRows.Close()

		out.Sources = append(out.Sources, SyncSourceState{
			SourceID:      src.ID,
			FinalSequence: src.FinalSequence,
			MissingRanges: missingRanges(seqs, src.FinalSequence, gaps),
			Gaps:          gaps,
			Receipts:      receipts,
		})
	}
	return out, nil
}
