package memories

import (
	"context"
	"database/sql"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
)

type DailySummaryRow struct {
	ID                 string  `json:"id"`
	UserID             string  `json:"user_id"`
	LocalDate          string  `json:"local_date"`
	Timezone           string  `json:"timezone"`
	SummaryEn          string  `json:"summary_en"`
	CoverageStartedAt  *string `json:"coverage_started_at"`
	CoverageEndedAt    *string `json:"coverage_ended_at"`
	Revision           int     `json:"revision"`
	State              string  `json:"state"`
	SourceCount        int     `json:"source_count"`
	ConsolidationRunID string  `json:"consolidation_run_id"`
	CreatedAt          string  `json:"created_at"`
	UpdatedAt          string  `json:"updated_at"`
}

func scanDailySummary(s interface{ Scan(...any) error }) (DailySummaryRow, error) {
	var r DailySummaryRow
	var covS, covE sql.NullString
	if err := s.Scan(&r.ID, &r.UserID, &r.LocalDate, &r.Timezone, &r.SummaryEn,
		&covS, &covE, &r.Revision, &r.State, &r.SourceCount, &r.ConsolidationRunID, &r.CreatedAt, &r.UpdatedAt); err != nil {
		return DailySummaryRow{}, err
	}
	if covS.Valid {
		r.CoverageStartedAt = &covS.String
	}
	if covE.Valid {
		r.CoverageEndedAt = &covE.String
	}
	return r, nil
}

type DailyFilter struct {
	Limit string
	From  string
	To    string
}

func ListDailySummaries(ctx context.Context, db *dbx.DB, userID string, f DailyFilter) ([]DailySummaryRow, error) {
	lim := transcripts.PageLimit(f.Limit, 200, 50)
	rows, err := db.R.QueryContext(ctx, `SELECT id, user_id, local_date, timezone, summary_en,
		coverage_started_at, coverage_ended_at, revision, state, source_count, consolidation_run_id, created_at, updated_at
		FROM daily_summaries WHERE user_id=? AND (?='' OR local_date>=?) AND (?='' OR local_date<=?)
		ORDER BY local_date DESC LIMIT ?`, userID, f.From, f.From, f.To, f.To, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DailySummaryRow{}
	for rows.Next() {
		if r, err := scanDailySummary(rows); err == nil {
			out = append(out, r)
		}
	}
	return out, nil
}

func GetDailySummary(ctx context.Context, db *dbx.DB, userID, dateStr string) (DailySummaryRow, error) {
	row := db.R.QueryRowContext(ctx, `SELECT id, user_id, local_date, timezone, summary_en,
		coverage_started_at, coverage_ended_at, revision, state, source_count, consolidation_run_id, created_at, updated_at
		FROM daily_summaries WHERE user_id=? AND local_date=? ORDER BY updated_at DESC LIMIT 1`, userID, dateStr)
	r, err := scanDailySummary(row)
	if err == sql.ErrNoRows {
		return DailySummaryRow{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Daily summary not found.")
	}
	return r, err
}

func LatestDailySummary(ctx context.Context, q conversations.Queryer, userID string) *ai.PreviousDailySummary {
	row := q.QueryRowContext(ctx, `SELECT local_date, timezone, summary_en, coverage_started_at, coverage_ended_at, source_count
		FROM daily_summaries WHERE user_id=? ORDER BY local_date DESC, updated_at DESC LIMIT 1`, userID)
	var out ai.PreviousDailySummary
	var cs, ce sql.NullString
	if err := row.Scan(&out.LocalDate, &out.Timezone, &out.SummaryEn, &cs, &ce, &out.SourceCount); err != nil {
		return nil
	}
	if cs.Valid {
		out.CoverageStartedAt = &cs.String
	}
	if ce.Valid {
		out.CoverageEndedAt = &ce.String
	}
	return &out
}

func UpsertDailySummaryTx(ctx context.Context, tx *sql.Tx, defaultMaxAttempts int, id, userID, localDate, tz, summary string, covStart, covEnd *string, state string, srcCount int, runID string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO daily_summaries
		(id, user_id, local_date, timezone, summary_en, coverage_started_at, coverage_ended_at, revision, state, source_count, consolidation_run_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
		ON CONFLICT(user_id, local_date, timezone) DO UPDATE SET
			summary_en=excluded.summary_en,
			coverage_started_at=COALESCE(MIN(daily_summaries.coverage_started_at, excluded.coverage_started_at), excluded.coverage_started_at),
			coverage_ended_at=COALESCE(MAX(daily_summaries.coverage_ended_at, excluded.coverage_ended_at), excluded.coverage_ended_at),
			revision=daily_summaries.revision + 1,
			state=excluded.state,
			source_count=excluded.source_count,
			consolidation_run_id=excluded.consolidation_run_id,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		id, userID, localDate, tz, summary, covStart, covEnd, state, srcCount, runID)
	if err != nil {
		return err
	}
	var actualID string
	_ = tx.QueryRowContext(ctx, `SELECT id FROM daily_summaries WHERE user_id=? AND local_date=? AND timezone=?`, userID, localDate, tz).Scan(&actualID)
	if actualID == "" {
		actualID = id
	}
	occ := localDate + "T23:59:59.000Z"
	if covEnd != nil && *covEnd != "" {
		occ = *covEnd
	}
	title := "Daily summary: " + localDate
	_, err = embeddings.UpsertDocumentExec(ctx, tx, defaultMaxAttempts, userID, "daily_summary", actualID, &title, summary, occ, 6)
	return err
}
