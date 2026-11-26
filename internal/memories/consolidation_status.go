package memories

import (
	"context"
	"database/sql"
	"errors"
)

// Eligibility says whether a consolidation could start now, and why not.
type Eligibility struct {
	Eligible           bool   `json:"eligible"`
	Queued             bool   `json:"queued,omitempty"`
	Reason             string `json:"reason,omitempty"`
	RunID              string `json:"runId,omitempty"`
	MaterialCharacters *int   `json:"materialCharacters,omitempty"`
	RequiredCharacters *int   `json:"requiredCharacters,omitempty"`
}

func (cs *ConsolidationService) Eligibility(ctx context.Context, userID string) (Eligibility, error) {
	if cs.Memories.AI == nil || !cs.Memories.AI.Ready(ctx) {
		return Eligibility{Reason: "ai_not_configured"}, nil
	}
	if cs.Usage != nil {
		if _, err := cs.Usage.RejectIfReached(ctx, userID, "ai"); err != nil {
			return Eligibility{Reason: "usage_limit"}, nil
		}
	}
	var active string
	err := cs.Memories.DB.R.QueryRowContext(ctx, `SELECT id FROM consolidation_runs WHERE user_id=? AND state IN ('reserved','running')
		ORDER BY reserved_at DESC LIMIT 1`, userID).Scan(&active)
	if err == nil {
		return Eligibility{Reason: "already_running", RunID: active}, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return Eligibility{}, err
	}
	conversations, characters, err := cs.candidates(ctx, userID, true)
	if err != nil {
		return Eligibility{}, err
	}
	required := cs.Memories.cfg().MinNewMaterialChars
	state := Eligibility{Eligible: len(conversations) > 0, MaterialCharacters: &characters, RequiredCharacters: &required}
	if !state.Eligible {
		state.Reason = "insufficient_material"
	}
	return state, nil
}

// Start queues a consolidation the user asked for, or reports why none was.
func (cs *ConsolidationService) Start(ctx context.Context, userID string) (Eligibility, error) {
	queued, runID, err := cs.Request(ctx, userID, true)
	if err != nil {
		return Eligibility{}, err
	}
	if queued {
		return Eligibility{Eligible: true, Queued: true, RunID: runID}, nil
	}
	return cs.Eligibility(ctx, userID)
}

// Latest returns the newest run as stored, nil when there has been none.
func (cs *ConsolidationService) Latest(ctx context.Context, userID string) (map[string]any, error) {
	rows, err := cs.Memories.DB.R.QueryContext(ctx, `SELECT * FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT 1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil || !rows.Next() {
		return nil, errors.Join(err, rows.Err())
	}
	values := make([]any, len(columns))
	targets := make([]any, len(columns))
	for i := range values {
		targets[i] = &values[i]
	}
	if err := rows.Scan(targets...); err != nil {
		return nil, err
	}
	run := make(map[string]any, len(columns))
	for i, column := range columns {
		run[column] = values[i]
	}
	return run, nil
}
