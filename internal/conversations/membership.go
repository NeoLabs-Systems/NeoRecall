package conversations

import (
	"context"
	"database/sql"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

const (
	BoundaryMethod  = "time-context-embedding"
	BoundaryVersion = "1"
)

func AssignSegments(ctx context.Context, tx speakers.SQLExecQueryer, userID, conversationID string, ids []string, publicIDs bool) error {
	if len(ids) == 0 {
		return nil
	}
	col := "id"
	if publicIDs {
		col = "public_id"
	}
	args := make([]any, 0, 2+len(ids))
	args = append(args, conversationID, userID)
	for _, id := range ids {
		args = append(args, id)
	}
	_, err := tx.ExecContext(ctx, `UPDATE transcript_segments SET conversation_id=?
		WHERE user_id=? AND `+col+` IN (`+placeholders(len(ids))+`)`, args...)
	if err != nil {
		return err
	}
	var minS, maxE sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT MIN(started_at), MAX(ended_at) FROM transcript_segments
		WHERE conversation_id=? AND user_id=?`, conversationID, userID).Scan(&minS, &maxE); err == nil && minS.Valid && maxE.Valid {
		_, err = tx.ExecContext(ctx, `UPDATE conversations SET started_at=?, ended_at=?,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`,
			minS.String, maxE.String, conversationID, userID)
		return err
	}
	return nil
}

// CloseQuietOpenConversations closes open conversations whose last segment ended more than quietCloseMs ago.
func CloseQuietOpenConversations(ctx context.Context, db *dbx.DB, cfg config.Config, userID string) ([]string, error) {
	cutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -cfg.ConversationQuietCloseMs))
	rows, err := db.R.QueryContext(ctx, `SELECT id FROM conversations WHERE user_id=? AND state='open' AND ended_at<=?`, userID, cutoff)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if len(ids) == 0 {
		return nil, nil
	}
	tx, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `UPDATE conversations SET state='closed', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
			WHERE id=? AND user_id=? AND state='open'`, id, userID); err != nil {
			return nil, err
		}
		_ = speakers.RebuildConversationSpeakers(ctx, tx, userID, id)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return ids, nil
}

// GroupPendingSegments partitions unattached segments (conversation_id IS NULL) into provisional conversations and updates speaker rosters.
func GroupPendingSegments(ctx context.Context, db *dbx.DB, cfg config.Config, userID string) ([]string, error) {
	rows, err := db.R.QueryContext(ctx, `SELECT ts.public_id, ts.started_at, ts.ended_at, ac.session_id
		FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		WHERE ts.user_id=? AND ts.conversation_id IS NULL
		ORDER BY ts.started_at ASC, ts.ended_at ASC, ts.id ASC`, userID)
	if err != nil {
		return nil, err
	}
	type segMeta struct {
		pubID, startedAt, endedAt, sessionID string
	}
	var pending []segMeta
	for rows.Next() {
		var m segMeta
		if rows.Scan(&m.pubID, &m.startedAt, &m.endedAt, &m.sessionID) == nil {
			pending = append(pending, m)
		}
	}
	rows.Close()
	if len(pending) == 0 {
		return nil, nil
	}

	tx, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Find active open conversation per user.
	var openConvID, openEndedAt, openStartedAt string
	var openChars int
	err = tx.QueryRowContext(ctx, `SELECT id, started_at, ended_at,
		(SELECT COALESCE(SUM(LENGTH(text)), 0) FROM transcript_segments WHERE conversation_id=conversations.id)
		FROM conversations WHERE user_id=? AND state='open'
		ORDER BY ended_at DESC LIMIT 1`, userID).Scan(&openConvID, &openStartedAt, &openEndedAt, &openChars)
	if err != nil {
		openConvID = ""
	}

	touched := make(map[string]bool)
	var touchedOrder []string
	markTouched := func(id string) {
		if !touched[id] {
			touched[id] = true
			touchedOrder = append(touchedOrder, id)
		}
	}

	closeConv := func(id string) error {
		_, err := tx.ExecContext(ctx, `UPDATE conversations SET state='closed', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
			WHERE id=? AND user_id=? AND state='open'`, id, userID)
		return err
	}

	hardGap := cfg.ConversationHardGapMs
	if hardGap <= 0 {
		hardGap = 600_000
	}
	maxMs := cfg.ConversationMaximumMs
	if maxMs <= 0 {
		maxMs = 4 * 60 * 60_000
	}

	var curID = openConvID
	var curStart = openStartedAt
	var curEnd = openEndedAt
	var batch []string

	flushBatch := func() error {
		if curID == "" || len(batch) == 0 {
			batch = nil
			return nil
		}
		if err := AssignSegments(ctx, tx, userID, curID, batch, true); err != nil {
			return err
		}
		markTouched(curID)
		batch = nil
		return nil
	}

	for _, seg := range pending {
		needNew := curID == ""
		if !needNew && curEnd != "" {
			gap := DurationMs(curEnd, seg.startedAt)
			totalSpan := DurationMs(curStart, seg.endedAt)
			if gap >= hardGap || totalSpan >= maxMs {
				needNew = true
			}
		}
		if needNew {
			if err := flushBatch(); err != nil {
				return nil, err
			}
			if curID != "" {
				if err := closeConv(curID); err != nil {
					return nil, err
				}
			}
			curID = uuid.NewString()
			curStart = seg.startedAt
			curEnd = seg.endedAt
			if _, err := tx.ExecContext(ctx, `INSERT INTO conversations
				(id, user_id, started_at, ended_at, state, boundary_method, boundary_version)
				VALUES (?, ?, ?, ?, 'open', ?, ?)`,
				curID, userID, seg.startedAt, seg.endedAt, BoundaryMethod, BoundaryVersion); err != nil {
				return nil, err
			}
		} else {
			if seg.endedAt > curEnd {
				curEnd = seg.endedAt
			}
		}
		batch = append(batch, seg.pubID)
	}
	if err := flushBatch(); err != nil {
		return nil, err
	}

	for _, id := range touchedOrder {
		_ = speakers.RebuildConversationSpeakers(ctx, tx, userID, id)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return touchedOrder, nil
}
