package conversations

import (
	"context"
	"database/sql"
	"net/http"

	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
)

const PendingID = "pending"

type PendingMoment struct {
	ID           string       `json:"id"`
	UserID       string       `json:"user_id"`
	StartedAt    string       `json:"started_at"`
	EndedAt      string       `json:"ended_at"`
	State        string       `json:"state"`
	SegmentCount int          `json:"segment_count"`
	Segments     []SegmentRow `json:"segments,omitempty"`
}

func GetPending(ctx context.Context, q Queryer, userID string, withSegments bool) (*PendingMoment, error) {
	var minS, maxE sql.NullString
	var cnt int
	err := q.QueryRowContext(ctx, `SELECT MIN(started_at), MAX(ended_at), COUNT(*)
		FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL`, userID).
		Scan(&minS, &maxE, &cnt)
	if err != nil {
		return nil, err
	}
	if cnt == 0 || !minS.Valid || !maxE.Valid {
		return nil, nil
	}
	p := &PendingMoment{
		ID:           PendingID,
		UserID:       userID,
		StartedAt:    minS.String,
		EndedAt:      maxE.String,
		State:        "pending",
		SegmentCount: cnt,
	}
	if withSegments {
		rows, err := q.QueryContext(ctx, `SELECT ts.id, ts.public_id, ts.user_id, ts.chunk_id, ts.conversation_id,
			ts.speaker_cluster_id, ts.source_component, ts.started_at, ts.ended_at, ts.chunk_start_ms,
			ts.chunk_end_ms, ts.text, ts.language, ts.asr_confidence, ts.speaker_confidence,
			ts.overlapping_speech, ts.created_at, ac.session_id
			FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
			WHERE ts.user_id=? AND ts.conversation_id IS NULL
			ORDER BY ts.started_at ASC, ts.ended_at ASC, ts.id ASC`, userID)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			if r, err := scanSegment(rows, true); err == nil {
				p.Segments = append(p.Segments, r)
			}
		}
		if p.Segments == nil {
			p.Segments = []SegmentRow{}
		}
	}
	return p, nil
}

func Timeline(ctx context.Context, q Queryer, userID string, limitRaw, from, to string) (map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	conds := []string{"user_id=?"}
	args := []any{userID}
	if from != "" {
		conds = append(conds, "ended_at>=?")
		args = append(args, from)
	}
	if to != "" {
		conds = append(conds, "started_at<=?")
		args = append(args, to)
	}
	args = append(args, lim)
	rows, err := q.QueryContext(ctx, `SELECT `+convSelectCols+`,
		(SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		 WHERE ts.conversation_id=conversations.id ORDER BY ts.started_at LIMIT 1) AS session_id
		FROM conversations WHERE `+joinConds(conds)+` ORDER BY started_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ConversationRow{}
	for rows.Next() {
		if c, err := scanConversation(rows, true); err == nil {
			items = append(items, c)
		}
	}
	pending, err := GetPending(ctx, q, userID, false)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"items":   items,
		"pending": pending,
	}, nil
}

func MustGetPending(ctx context.Context, q Queryer, userID string) (*PendingMoment, error) {
	p, err := GetPending(ctx, q, userID, true)
	if err != nil {
		return nil, err
	}
	if p == nil {
		return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "No pending transcript segments found.")
	}
	return p, nil
}
