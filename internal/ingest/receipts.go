package ingest

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

var TerminalStates = map[string]bool{
	"transcribed": true,
	"silent":      true,
}

type Estimate struct {
	QueuePosition        int
	EstimatedRemainingMs *int
	EstimateBasis        string
}

type Receipt struct {
	ChunkID                string  `json:"chunkId"`
	SourceID               string  `json:"sourceId"`
	Sequence               int     `json:"sequence"`
	State                  string  `json:"state"`
	ReceiptVersion         int     `json:"receiptVersion"`
	ErrorCode              string  `json:"errorCode,omitempty"`
	TranscriptSegmentCount *int    `json:"transcriptSegmentCount,omitempty"`
	TranscriptSha256       *string `json:"transcriptSha256,omitempty"`
	PersistedAt            *string `json:"persistedAt,omitempty"`
	ServerAudioDeletedAt   *string `json:"serverAudioDeletedAt,omitempty"`
	QueuePosition          *int    `json:"queuePosition,omitempty"`
	EstimatedRemainingMs   *int    `json:"estimatedRemainingMs,omitempty"`
	EstimateBasis          string  `json:"estimateBasis,omitempty"`
	Duplicate              bool    `json:"-"`
}

type chunkRow struct {
	ID                     string
	UserID                 string
	SessionID              string
	SourceID               string
	Sequence               int
	IdempotencyKey         string
	SHA256                 string
	ByteSize               int64
	DurationMs             int
	OverlapMs              int
	ChannelLayout          string
	MonotonicOffsetMs      int64
	State                  string
	TemporaryPath          sql.NullString
	ReceiptVersion         int
	ErrorCode              sql.NullString
	TranscriptSegmentCount sql.NullInt64
	TranscriptSHA256       sql.NullString
	PersistedAt            sql.NullString
	ServerDeletedAt        sql.NullString
}

type Receipts struct {
	DB *dbx.DB
}

func (r *Receipts) ProcessingEstimateContext(ctx context.Context) map[string]Estimate {
	estimates := map[string]Estimate{}
	var avg sql.NullFloat64
	_ = r.DB.R.QueryRowContext(ctx, `SELECT AVG(value) FROM (
		SELECT value FROM processing_metrics WHERE metric='transcription_pipeline_rtf' AND value > 0
		ORDER BY created_at DESC LIMIT 100
	)`).Scan(&avg)
	hasRTF := avg.Valid && !math.IsNaN(avg.Float64) && !math.IsInf(avg.Float64, 0)

	rows, err := r.DB.R.QueryContext(ctx, `SELECT j.resource_id, j.status, j.started_at, c.duration_ms
		FROM jobs j JOIN audio_chunks c ON c.id=j.resource_id
		WHERE j.type='transcribe_chunk' AND j.status IN ('queued','leased')
		ORDER BY CASE WHEN j.status='leased' THEN 0 ELSE 1 END, j.priority DESC, j.created_at ASC`)
	if err != nil {
		return estimates
	}
	defer rows.Close()

	var cumulativeMs float64
	now := time.Now()
	idx := 0
	for rows.Next() {
		var resID, st string
		var startedAt sql.NullString
		var durMs int
		if rows.Scan(&resID, &st, &startedAt, &durMs) != nil {
			continue
		}
		if hasRTF {
			expectedMs := max(0.0, float64(durMs)*avg.Float64)
			var elapsedMs float64
			if st == "leased" && startedAt.Valid {
				if t, err := timeutil.ParseISO(startedAt.String); err == nil {
					elapsedMs = max(0.0, float64(now.Sub(t).Milliseconds()))
				}
			}
			cumulativeMs += max(0.0, expectedMs-elapsedMs)
		}
		qPos := idx
		if st == "leased" {
			qPos = 0
		}
		var remPtr *int
		basis := ""
		if hasRTF {
			v := int(math.Ceil(cumulativeMs))
			remPtr = &v
			basis = "observed_transcription_rtf"
		}
		estimates[resID] = Estimate{QueuePosition: qPos, EstimatedRemainingMs: remPtr, EstimateBasis: basis}
		idx++
	}
	return estimates
}

func formatReceipt(row chunkRow, estCtx map[string]Estimate) Receipt {
	rec := Receipt{
		ChunkID:        row.ID,
		SourceID:       row.SourceID,
		Sequence:       row.Sequence,
		State:          row.State,
		ReceiptVersion: row.ReceiptVersion,
		ErrorCode:      row.ErrorCode.String,
	}
	if TerminalStates[row.State] {
		if row.TranscriptSegmentCount.Valid {
			c := int(row.TranscriptSegmentCount.Int64)
			rec.TranscriptSegmentCount = &c
		}
		if row.TranscriptSHA256.Valid {
			h := row.TranscriptSHA256.String
			rec.TranscriptSha256 = &h
		}
		if row.PersistedAt.Valid {
			p := row.PersistedAt.String
			rec.PersistedAt = &p
		}
		if row.ServerDeletedAt.Valid {
			d := row.ServerDeletedAt.String
			rec.ServerAudioDeletedAt = &d
		}
		return rec
	}
	if estCtx != nil {
		if est, ok := estCtx[row.ID]; ok {
			qp := est.QueuePosition
			rec.QueuePosition = &qp
			rec.EstimatedRemainingMs = est.EstimatedRemainingMs
			rec.EstimateBasis = est.EstimateBasis
		}
	}
	return rec
}

func scanChunk(q interface{ Scan(...any) error }) (chunkRow, error) {
	var c chunkRow
	err := q.Scan(&c.ID, &c.UserID, &c.SessionID, &c.SourceID, &c.Sequence, &c.IdempotencyKey, &c.SHA256,
		&c.ByteSize, &c.DurationMs, &c.OverlapMs, &c.ChannelLayout, &c.MonotonicOffsetMs, &c.State, &c.TemporaryPath,
		&c.ReceiptVersion, &c.ErrorCode, &c.TranscriptSegmentCount, &c.TranscriptSHA256, &c.PersistedAt, &c.ServerDeletedAt)
	return c, err
}

const chunkSelectCols = `id, user_id, session_id, source_id, sequence, idempotency_key, sha256,
	byte_size, duration_ms, overlap_ms, channel_layout, monotonic_offset_ms, state, temporary_path,
	receipt_version, error_code, transcript_segment_count, transcript_sha256, persisted_at, server_deleted_at`

func (r *Receipts) FindForUser(ctx context.Context, userID, chunkID string) (*Receipt, error) {
	row, err := scanChunk(r.DB.R.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE id=? AND user_id=?`, chunkID, userID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	est := r.ProcessingEstimateContext(ctx)
	rec := formatReceipt(row, est)
	return &rec, nil
}

// CompleteTerminal validates that derived segments are persisted and temporary_path
// is NULL (server audio deleted) before marking a chunk transcribed or silent.
func CompleteTerminalTx(ctx context.Context, tx *sql.Tx, chunkID, state, serverDeletedAt string) (Receipt, error) {
	if !TerminalStates[state] {
		return Receipt{}, errors.New("invalid terminal receipt state: " + state)
	}
	if serverDeletedAt == "" {
		serverDeletedAt = timeutil.NowISO()
	}
	row, err := scanChunk(tx.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE id=?`, chunkID))
	if err != nil || row.State != "persisted_cleanup_pending" || !row.PersistedAt.Valid || row.TemporaryPath.Valid {
		return Receipt{}, errors.New("a terminal receipt requires persisted transcript state and an absent temporary path")
	}
	if _, err := tx.ExecContext(ctx, `UPDATE audio_chunks SET state=?, server_deleted_at=?, receipt_version=receipt_version+1,
		updated_at=? WHERE id=?`, state, serverDeletedAt, serverDeletedAt, chunkID); err != nil {
		return Receipt{}, err
	}
	updated, err := scanChunk(tx.QueryRowContext(ctx, `SELECT `+chunkSelectCols+` FROM audio_chunks WHERE id=?`, chunkID))
	if err != nil {
		return Receipt{}, err
	}
	return formatReceipt(updated, nil), nil
}
