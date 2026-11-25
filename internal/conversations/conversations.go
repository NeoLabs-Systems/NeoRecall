package conversations

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
)

type ConversationSpeaker struct {
	ConversationID string  `json:"conversation_id"`
	ClusterID      string  `json:"cluster_id"`
	VoiceprintID   *string `json:"voiceprint_id"`
	LocalLabel     string  `json:"local_label"`
}

const BulkMax = 100

type Service struct {
	DB                     *dbx.DB
	Cfg                    func() config.Config
	Log                    *slog.Logger
	AIReadyFn              func(ctx context.Context) bool
	OnRequestConsolidation func(ctx context.Context, userID string, manual bool) (queued bool, runID string, err error)
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func joinConds(conds []string) string {
	return strings.Join(conds, " AND ")
}

type ListFilter struct {
	Limit   string
	State   string
	From    string
	To      string
	Speaker string
}

func (s *Service) List(ctx context.Context, userID string, f ListFilter) ([]ConversationRow, error) {
	lim := transcripts.PageLimit(f.Limit, 200, 50)
	conds := []string{"user_id=?"}
	args := []any{userID}
	if f.State != "" {
		conds = append(conds, "state=?")
		args = append(args, f.State)
	}
	if f.From != "" {
		conds = append(conds, "ended_at>=?")
		args = append(args, f.From)
	}
	if f.To != "" {
		conds = append(conds, "started_at<=?")
		args = append(args, f.To)
	}
	if f.Speaker != "" {
		conds = append(conds, `EXISTS (SELECT 1 FROM conversation_speakers cs WHERE cs.conversation_id=conversations.id AND (cs.voiceprint_id=? OR cs.cluster_id=?))`)
		args = append(args, f.Speaker, f.Speaker)
	}
	args = append(args, lim)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+convSelectCols+`,
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
	return items, nil
}

type Detail struct {
	ConversationRow
	Segments []SegmentRow          `json:"segments"`
	Speakers []ConversationSpeaker `json:"speakers"`
}

func (s *Service) Get(ctx context.Context, userID, id string) (Detail, error) {
	row := s.DB.R.QueryRowContext(ctx, `SELECT `+convSelectCols+` FROM conversations WHERE id=? AND user_id=?`, id, userID)
	c, err := scanConversation(row, false)
	if err == sql.ErrNoRows {
		return Detail{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Conversation not found.")
	}
	if err != nil {
		return Detail{}, err
	}
	segs, err := SegmentsOf(ctx, s.DB.R, userID, id)
	if err != nil {
		return Detail{}, err
	}
	if segs == nil {
		segs = []SegmentRow{}
	}
	spks := []ConversationSpeaker{}
	srows, err := s.DB.R.QueryContext(ctx, `SELECT conversation_id, cluster_id, voiceprint_id, local_label
		FROM conversation_speakers WHERE conversation_id=?`, id)
	if err == nil {
		for srows.Next() {
			var cs ConversationSpeaker
			var vp sql.NullString
			if srows.Scan(&cs.ConversationID, &cs.ClusterID, &vp, &cs.LocalLabel) == nil {
				if vp.Valid {
					cs.VoiceprintID = &vp.String
				}
				spks = append(spks, cs)
			}
		}
		srows.Close()
	}
	return Detail{ConversationRow: c, Segments: segs, Speakers: spks}, nil
}

func (s *Service) BulkRemove(ctx context.Context, userID string, ids []string) (map[string]any, error) {
	if len(ids) == 0 {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_IDS", "Provide at least one moment id.")
	}
	if len(ids) > BulkMax {
		return nil, httperr.New(http.StatusBadRequest, "TOO_MANY_IDS", "At most 100 moments per bulk action.")
	}
	seen := make(map[string]bool, len(ids))
	var uniqueIDs, convIDs []string
	includePending := false
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		uniqueIDs = append(uniqueIDs, id)
		if id == PendingID {
			includePending = true
		} else {
			convIDs = append(convIDs, id)
		}
	}
	if len(uniqueIDs) == 0 {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_IDS", "Provide at least one moment id.")
	}
	if len(convIDs) > 0 {
		args := make([]any, 0, 1+len(convIDs))
		args = append(args, userID)
		for _, id := range convIDs {
			args = append(args, id)
		}
		var cnt int
		_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE user_id=? AND id IN (`+placeholders(len(convIDs))+`)`, args...).Scan(&cnt)
		if cnt != len(convIDs) {
			return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "One or more conversations were not found.")
		}
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	segSet := make(map[int64]bool)
	var segIDs []int64
	if len(convIDs) > 0 {
		args := append([]any{userID}, anySlice(convIDs)...)
		rows, err := tx.QueryContext(ctx, `SELECT id FROM transcript_segments WHERE user_id=? AND conversation_id IN (`+placeholders(len(convIDs))+`)`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var sid int64
			if rows.Scan(&sid) == nil && !segSet[sid] {
				segSet[sid] = true
				segIDs = append(segIDs, sid)
			}
		}
		rows.Close()
	}
	if includePending {
		rows, err := tx.QueryContext(ctx, `SELECT id FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL`, userID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var sid int64
			if rows.Scan(&sid) == nil && !segSet[sid] {
				segSet[sid] = true
				segIDs = append(segIDs, sid)
			}
		}
		rows.Close()
	}

	memIDs, err := exclusiveMemoriesTx(ctx, tx, userID, convIDs, segIDs)
	if err != nil {
		return nil, err
	}
	var miniIDs []int64
	var origPaths []string
	if len(memIDs) > 0 {
		args := append([]any{userID}, anyIntSlice(memIDs)...)
		ph := placeholders(len(memIDs))
		mrows, err := tx.QueryContext(ctx, `SELECT id FROM mini_memories WHERE user_id=? AND memory_id IN (`+ph+`)`, args...)
		if err == nil {
			for mrows.Next() {
				var mid int64
				if mrows.Scan(&mid) == nil {
					miniIDs = append(miniIDs, mid)
				}
			}
			mrows.Close()
		}
		crows, err := tx.QueryContext(ctx, `SELECT original_path FROM recording_context_items WHERE user_id=? AND memory_id IN (`+ph+`) AND original_path IS NOT NULL`, args...)
		if err == nil {
			for crows.Next() {
				var p string
				if crows.Scan(&p) == nil && p != "" {
					origPaths = append(origPaths, p)
				}
			}
			crows.Close()
		}
	}

	var refs []embeddings.SearchSourceRef
	for _, id := range segIDs {
		refs = append(refs, embeddings.SearchSourceRef{Kind: "segment", SourceID: intStr(id)})
	}
	for _, id := range memIDs {
		refs = append(refs, embeddings.SearchSourceRef{Kind: "memory", SourceID: intStr(id)})
	}
	for _, id := range miniIDs {
		refs = append(refs, embeddings.SearchSourceRef{Kind: "mini_memory", SourceID: intStr(id)})
	}
	if _, err := embeddings.RemoveBySourcesTx(ctx, tx, userID, refs); err != nil {
		return nil, err
	}

	if len(memIDs) > 0 {
		args := append([]any{userID}, anyIntSlice(memIDs)...)
		if _, err := tx.ExecContext(ctx, `DELETE FROM memories WHERE user_id=? AND id IN (`+placeholders(len(memIDs))+`)`, args...); err != nil {
			return nil, err
		}
	}
	if len(segIDs) > 0 {
		args := append([]any{userID}, anyIntSlice(segIDs)...)
		if _, err := tx.ExecContext(ctx, `DELETE FROM transcript_segments WHERE user_id=? AND id IN (`+placeholders(len(segIDs))+`)`, args...); err != nil {
			return nil, err
		}
	}
	if len(convIDs) > 0 {
		args := append([]any{userID}, anySlice(convIDs)...)
		ph := placeholders(len(convIDs))
		_, _ = tx.ExecContext(ctx, `UPDATE jobs SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
			updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
			WHERE user_id=? AND status IN ('queued','leased') AND resource_type='conversation'
			  AND resource_id IN (`+ph+`)`, args...)
		if _, err := tx.ExecContext(ctx, `DELETE FROM conversations WHERE user_id=? AND id IN (`+ph+`)`, args...); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	for _, p := range origPaths {
		_ = os.Remove(p)
	}
	return map[string]any{"action": "delete", "count": len(uniqueIDs), "ids": uniqueIDs}, nil
}

func (s *Service) Remove(ctx context.Context, userID, id string) error {
	_, err := s.BulkRemove(ctx, userID, []string{id})
	return err
}

func (s *Service) Reprocess(ctx context.Context, userID, convID string) (map[string]any, error) {
	var state string
	err := s.DB.R.QueryRowContext(ctx, `SELECT state FROM conversations WHERE id=? AND user_id=?`, convID, userID).Scan(&state)
	if err == sql.ErrNoRows {
		return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Conversation not found.")
	}
	if err != nil {
		return nil, err
	}
	if state == "open" {
		return nil, httperr.New(http.StatusConflict, "CONVERSATION_OPEN", "This conversation is still being recorded.")
	}
	if s.AIReadyFn != nil && !s.AIReadyFn(ctx) {
		return nil, httperr.New(http.StatusConflict, "AI_NOT_CONFIGURED", "No language model is configured.")
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	rows, err := tx.QueryContext(ctx, `SELECT m.id FROM memories m
		WHERE m.user_id=? AND EXISTS (
			SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND s.conversation_id=?
		) AND NOT EXISTS (
			SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND s.conversation_id IS NOT NULL AND s.conversation_id<>?
		)`, userID, convID, convID)
	if err != nil {
		return nil, err
	}
	var ownedMemIDs []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ownedMemIDs = append(ownedMemIDs, id)
		}
	}
	rows.Close()

	for _, memID := range ownedMemIDs {
		mrows, _ := tx.QueryContext(ctx, `SELECT id FROM mini_memories WHERE memory_id=? AND user_id=?`, memID, userID)
		var refs []embeddings.SearchSourceRef
		refs = append(refs, embeddings.SearchSourceRef{Kind: "memory", SourceID: intStr(memID)})
		if mrows != nil {
			for mrows.Next() {
				var miniID int64
				if mrows.Scan(&miniID) == nil {
					refs = append(refs, embeddings.SearchSourceRef{Kind: "mini_memory", SourceID: intStr(miniID)})
				}
			}
			mrows.Close()
		}
		_, _ = embeddings.RemoveBySourcesTx(ctx, tx, userID, refs)
		if _, err := tx.ExecContext(ctx, `DELETE FROM memories WHERE id=? AND user_id=?`, memID, userID); err != nil {
			return nil, err
		}
	}

	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET state='closed', refined_at=NULL, refinement_run_id=NULL,
		memory_worthy=NULL, insight_state=CASE WHEN insight_state IS NULL THEN NULL ELSE 'provisional' END,
		consolidation_failures=0, quarantined_at=NULL, quarantine_reason=NULL,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`, convID, userID); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	queued := false
	var runID any
	if s.OnRequestConsolidation != nil {
		q, rid, _ := s.OnRequestConsolidation(ctx, userID, true)
		queued = q
		if rid != "" {
			runID = rid
		}
	}
	return map[string]any{
		"conversationId":   convID,
		"replacedMemories": len(ownedMemIDs),
		"queued":           queued,
		"runId":            runID,
	}, nil
}

func exclusiveMemoriesTx(ctx context.Context, tx *sql.Tx, userID string, convIDs []string, segIDs []int64) ([]int64, error) {
	if len(convIDs) == 0 && len(segIDs) == 0 {
		return nil, nil
	}
	convClause, otherConvClause := "0", "s.conversation_id IS NOT NULL"
	if len(convIDs) > 0 {
		ph := placeholders(len(convIDs))
		convClause = "s.conversation_id IN (" + ph + ")"
		otherConvClause = "s.conversation_id IS NOT NULL AND s.conversation_id NOT IN (" + ph + ")"
	}
	segClause, otherSegClause := "0", "s.segment_id IS NOT NULL"
	if len(segIDs) > 0 {
		ph := placeholders(len(segIDs))
		segClause = "s.segment_id IN (" + ph + ")"
		otherSegClause = "s.segment_id IS NOT NULL AND s.segment_id NOT IN (" + ph + ")"
	}
	args := []any{userID}
	args = append(args, anySlice(convIDs)...)
	args = append(args, anyIntSlice(segIDs)...)
	args = append(args, anySlice(convIDs)...)
	args = append(args, anyIntSlice(segIDs)...)

	rows, err := tx.QueryContext(ctx, `SELECT m.id FROM memories m
		WHERE m.user_id=? AND EXISTS (
			SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND (`+convClause+` OR `+segClause+`)
		) AND NOT EXISTS (
			SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND ((`+otherConvClause+`) OR (`+otherSegClause+`))
		)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			out = append(out, id)
		}
	}
	return out, nil
}

func anySlice(in []string) []any {
	out := make([]any, len(in))
	for i, s := range in {
		out[i] = s
	}
	return out
}

func anyIntSlice(in []int64) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

func intStr(v int64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	pos := len(buf)
	for v > 0 {
		pos--
		buf[pos] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[pos:])
}
