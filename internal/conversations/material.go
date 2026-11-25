package conversations

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type Queryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type ConversationRow struct {
	ID                    string   `json:"id"`
	UserID                string   `json:"user_id"`
	SessionID             *string  `json:"session_id,omitempty"`
	StartedAt             string   `json:"started_at"`
	EndedAt               string   `json:"ended_at"`
	State                 string   `json:"state"`
	BoundaryMethod        string   `json:"boundary_method"`
	BoundaryScore         *float64 `json:"boundary_score"`
	BoundaryVersion       string   `json:"boundary_version"`
	TitleEn               *string  `json:"title_en"`
	SummaryEn             *string  `json:"summary_en"`
	Topics                []string `json:"topics"`
	MemoryWorthy          *bool    `json:"memory_worthy"`
	InsightState          string   `json:"insight_state"`
	InsightCharacters     int      `json:"insight_characters"`
	InsightUpdatedAt      *string  `json:"insight_updated_at"`
	InsightAttemptedAt    *string  `json:"insight_attempted_at"`
	InsightCoveredThrough *string  `json:"insight_covered_through"`
	InsightRequestID      *string  `json:"insight_request_id"`
	RefinedAt             *string  `json:"refined_at"`
	RefinementRunID       *string  `json:"refinement_run_id"`
	OriginConversationID  *string  `json:"origin_conversation_id"`
	ConsolidationFailures int      `json:"consolidation_failures"`
	QuarantinedAt         *string  `json:"quarantined_at"`
	QuarantineReason      *string  `json:"quarantine_reason"`
	CreatedAt             string   `json:"created_at"`
	UpdatedAt             string   `json:"updated_at"`
}

const convSelectCols = `id, user_id, started_at, ended_at, state, boundary_method, boundary_score, boundary_version,
	title_en, summary_en, topics_json, memory_worthy, insight_state, insight_characters, insight_updated_at,
	insight_attempted_at, insight_covered_through, insight_request_id, refined_at, refinement_run_id,
	origin_conversation_id, consolidation_failures, quarantined_at, quarantine_reason, created_at, updated_at`

func scanConversation(s interface{ Scan(...any) error }, withSession bool) (ConversationRow, error) {
	var c ConversationRow
	var bScore sql.NullFloat64
	var title, summary, topicsJSON, insUpd, insAtt, insCov, insReq, refAt, refRun, origID, qAt, qReason, sess sql.NullString
	var memWorthy sql.NullInt64
	var dest []any
	dest = append(dest, &c.ID, &c.UserID, &c.StartedAt, &c.EndedAt, &c.State, &c.BoundaryMethod, &bScore, &c.BoundaryVersion,
		&title, &summary, &topicsJSON, &memWorthy, &c.InsightState, &c.InsightCharacters, &insUpd,
		&insAtt, &insCov, &insReq, &refAt, &refRun, &origID, &c.ConsolidationFailures, &qAt, &qReason, &c.CreatedAt, &c.UpdatedAt)
	if withSession {
		dest = append(dest, &sess)
	}
	if err := s.Scan(dest...); err != nil {
		return ConversationRow{}, err
	}
	if bScore.Valid {
		v := bScore.Float64
		c.BoundaryScore = &v
	}
	if title.Valid {
		c.TitleEn = &title.String
	}
	if summary.Valid {
		c.SummaryEn = &summary.String
	}
	if topicsJSON.Valid && topicsJSON.String != "" {
		_ = json.Unmarshal([]byte(topicsJSON.String), &c.Topics)
	}
	if c.Topics == nil {
		c.Topics = []string{}
	}
	if memWorthy.Valid {
		b := memWorthy.Int64 != 0
		c.MemoryWorthy = &b
	}
	if insUpd.Valid {
		c.InsightUpdatedAt = &insUpd.String
	}
	if insAtt.Valid {
		c.InsightAttemptedAt = &insAtt.String
	}
	if insCov.Valid {
		c.InsightCoveredThrough = &insCov.String
	}
	if insReq.Valid {
		c.InsightRequestID = &insReq.String
	}
	if refAt.Valid {
		c.RefinedAt = &refAt.String
	}
	if refRun.Valid {
		c.RefinementRunID = &refRun.String
	}
	if origID.Valid {
		c.OriginConversationID = &origID.String
	}
	if qAt.Valid {
		c.QuarantinedAt = &qAt.String
	}
	if qReason.Valid {
		c.QuarantineReason = &qReason.String
	}
	if sess.Valid {
		c.SessionID = &sess.String
	}
	return c, nil
}

type SegmentRow struct {
	ID                int64    `json:"id"`
	PublicID          string   `json:"public_id"`
	UserID            string   `json:"user_id"`
	ChunkID           string   `json:"chunk_id"`
	SessionID         string   `json:"session_id,omitempty"`
	ConversationID    *string  `json:"conversation_id"`
	SpeakerClusterID  *string  `json:"speaker_cluster_id"`
	SourceComponent   string   `json:"source_component"`
	StartedAt         string   `json:"started_at"`
	EndedAt           string   `json:"ended_at"`
	ChunkStartMs      int64    `json:"chunk_start_ms"`
	ChunkEndMs        int64    `json:"chunk_end_ms"`
	Text              string   `json:"text"`
	Language          *string  `json:"language"`
	ASRConfidence     *float64 `json:"asr_confidence"`
	SpeakerConfidence *float64 `json:"speaker_confidence"`
	OverlappingSpeech bool     `json:"overlapping_speech"`
	CreatedAt         string   `json:"created_at"`
	VoiceprintName    *string  `json:"voiceprint_name,omitempty"`
	LocalLabel        *string  `json:"local_label,omitempty"`
}

func scanSegment(s interface{ Scan(...any) error }, withSession bool, withNames ...bool) (SegmentRow, error) {
	var r SegmentRow
	var convID, spkID, lang, voiceName, localLabel sql.NullString
	var asrC, spkC sql.NullFloat64
	var ov int
	dest := []any{
		&r.ID, &r.PublicID, &r.UserID, &r.ChunkID, &convID, &spkID, &r.SourceComponent,
		&r.StartedAt, &r.EndedAt, &r.ChunkStartMs, &r.ChunkEndMs, &r.Text,
		&lang, &asrC, &spkC, &ov, &r.CreatedAt,
	}
	if withSession {
		dest = append(dest, &r.SessionID)
	}
	if len(withNames) > 0 && withNames[0] {
		dest = append(dest, &voiceName, &localLabel)
	}
	if err := s.Scan(dest...); err != nil {
		return SegmentRow{}, err
	}
	if convID.Valid {
		r.ConversationID = &convID.String
	}
	if spkID.Valid {
		r.SpeakerClusterID = &spkID.String
	}
	if lang.Valid {
		r.Language = &lang.String
	}
	if asrC.Valid {
		v := asrC.Float64
		r.ASRConfidence = &v
	}
	if spkC.Valid {
		v := spkC.Float64
		r.SpeakerConfidence = &v
	}
	if voiceName.Valid {
		r.VoiceprintName = &voiceName.String
	}
	if localLabel.Valid {
		r.LocalLabel = &localLabel.String
	}
	r.OverlappingSpeech = ov != 0
	return r, nil
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

func ListByState(ctx context.Context, q Queryer, userID string, states []string, includeQuarantined bool) ([]ConversationRow, error) {
	if len(states) == 0 {
		return nil, nil
	}
	qClause := ""
	if !includeQuarantined {
		qClause = " AND quarantined_at IS NULL"
	}
	args := []any{userID}
	for _, st := range states {
		args = append(args, st)
	}
	rows, err := q.QueryContext(ctx, `SELECT `+convSelectCols+`,
		(SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		 WHERE ts.conversation_id=conversations.id ORDER BY ts.started_at LIMIT 1) AS session_id
		FROM conversations WHERE user_id=? AND state IN (`+placeholders(len(states))+`)`+qClause+`
		ORDER BY started_at ASC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ConversationRow
	for rows.Next() {
		if c, err := scanConversation(rows, true); err == nil {
			out = append(out, c)
		}
	}
	return out, nil
}

func FindInState(ctx context.Context, q Queryer, userID, convID string, states []string, includeQuarantined bool) (*ConversationRow, error) {
	if len(states) == 0 {
		return nil, nil
	}
	qClause := ""
	if !includeQuarantined {
		qClause = " AND quarantined_at IS NULL"
	}
	args := []any{convID, userID}
	for _, st := range states {
		args = append(args, st)
	}
	row := q.QueryRowContext(ctx, `SELECT `+convSelectCols+`,
		(SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		 WHERE ts.conversation_id=conversations.id ORDER BY ts.started_at LIMIT 1) AS session_id
		FROM conversations WHERE id=? AND user_id=? AND state IN (`+placeholders(len(states))+`)`+qClause, args...)
	c, err := scanConversation(row, true)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func ListForSession(ctx context.Context, q Queryer, userID, sessionID string) ([]ConversationRow, error) {
	rows, err := q.QueryContext(ctx, `SELECT `+convSelectCols+`, ? AS session_id
		FROM conversations WHERE user_id=? AND EXISTS (
			SELECT 1 FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
			WHERE ts.conversation_id=conversations.id AND ac.session_id=?
		) ORDER BY started_at ASC`, sessionID, userID, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ConversationRow
	for rows.Next() {
		if c, err := scanConversation(rows, true); err == nil {
			out = append(out, c)
		}
	}
	return out, nil
}

func SegmentsOf(ctx context.Context, q Queryer, userID, convID string) ([]SegmentRow, error) {
	rows, err := q.QueryContext(ctx, `SELECT ts.id, ts.public_id, ts.user_id, ts.chunk_id, ts.conversation_id,
		ts.speaker_cluster_id, ts.source_component, ts.started_at, ts.ended_at, ts.chunk_start_ms,
		ts.chunk_end_ms, ts.text, ts.language, ts.asr_confidence, ts.speaker_confidence,
		ts.overlapping_speech, ts.created_at, ac.session_id
		FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		WHERE ts.conversation_id=? AND ts.user_id=?
		ORDER BY ts.started_at ASC, ts.ended_at ASC, ts.id ASC`, convID, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SegmentRow
	for rows.Next() {
		if r, err := scanSegment(rows, true); err == nil {
			out = append(out, r)
		}
	}
	return out, nil
}

func SegmentsAfter(ctx context.Context, q Queryer, userID, convID, afterEndedAt string) ([]SegmentRow, error) {
	rows, err := q.QueryContext(ctx, `SELECT ts.id, ts.public_id, ts.user_id, ts.chunk_id, ts.conversation_id,
		ts.speaker_cluster_id, ts.source_component, ts.started_at, ts.ended_at, ts.chunk_start_ms,
		ts.chunk_end_ms, ts.text, ts.language, ts.asr_confidence, ts.speaker_confidence,
		ts.overlapping_speech, ts.created_at, ac.session_id
		FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
		WHERE ts.conversation_id=? AND ts.user_id=? AND ts.ended_at>?
		ORDER BY ts.started_at ASC, ts.ended_at ASC, ts.id ASC`, convID, userID, afterEndedAt)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SegmentRow
	for rows.Next() {
		if r, err := scanSegment(rows, true); err == nil {
			out = append(out, r)
		}
	}
	return out, nil
}

func TranscriptCharacters(ctx context.Context, q Queryer, userID, convID string) int {
	var n int
	_ = q.QueryRowContext(ctx, `SELECT COALESCE(SUM(LENGTH(text)), 0) FROM transcript_segments WHERE conversation_id=? AND user_id=?`, convID, userID).Scan(&n)
	return n
}

func CharacterCount(segs []SegmentRow) int {
	n := 0
	for _, s := range segs {
		n += len(s.Text)
	}
	return n
}

func DurationMs(startedAt, endedAt string) int64 {
	s, err1 := timeutil.ParseISO(startedAt)
	e, err2 := timeutil.ParseISO(endedAt)
	if err1 != nil || err2 != nil {
		return 0
	}
	ms := e.Sub(s).Milliseconds()
	if ms < 0 {
		return 0
	}
	return ms
}

// IsComplete returns true when no queued/leased/failed incomplete audio chunks exist for the conversation's session before its span.
func IsComplete(ctx context.Context, q Queryer, userID, convID string) bool {
	var incomplete int
	_ = q.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks ac
		WHERE ac.user_id=? AND ac.state NOT IN ('transcribed','silent')
		  AND ac.session_id IN (
			SELECT DISTINCT ac2.session_id FROM transcript_segments ts JOIN audio_chunks ac2 ON ac2.id=ts.chunk_id
			WHERE ts.conversation_id=? AND ts.user_id=?
		  )`, userID, convID, userID).Scan(&incomplete)
	return incomplete == 0
}

func BuildMaterial(ctx context.Context, q Queryer, userID string, conv ConversationRow, ctxSvc *nctx.Service) (ai.InputConversation, int, error) {
	segs, err := SegmentsOf(ctx, q, userID, conv.ID)
	if err != nil {
		return ai.InputConversation{}, 0, err
	}
	inSegs := make([]ai.InputSegment, 0, len(segs))
	for _, s := range segs {
		inSegs = append(inSegs, ai.InputSegment{
			ID:               s.PublicID,
			StartedAt:        s.StartedAt,
			EndedAt:          s.EndedAt,
			Text:             s.Text,
			Language:         s.Language,
			SpeakerClusterID: s.SpeakerClusterID,
		})
	}
	sessID := conv.SessionID
	if sessID == nil && len(segs) > 0 && segs[0].SessionID != "" {
		v := segs[0].SessionID
		sessID = &v
	}
	out := ai.InputConversation{
		ID:        conv.ID,
		SessionID: sessID,
		StartedAt: conv.StartedAt,
		EndedAt:   conv.EndedAt,
		Segments:  inSegs,
	}
	if ctxSvc != nil {
		arr := []ai.InputConversation{out}
		ctxSvc.Attach(ctx, userID, arr)
		out = arr[0]
	}
	return out, CharacterCount(segs), nil
}

// Quarantine marks a conversation as quarantined after max repeated failures.
func Quarantine(ctx context.Context, ex interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}, userID, convID, reason string, cfg config.Config) error {
	maxF := max(1, cfg.ConsolidationMaxFailures)
	_, err := ex.ExecContext(ctx, `UPDATE conversations SET
		consolidation_failures = consolidation_failures + 1,
		quarantined_at = CASE WHEN consolidation_failures + 1 >= ? THEN COALESCE(quarantined_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')) ELSE quarantined_at END,
		quarantine_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=?`, maxF, fmt.Sprintf("%.240s", reason), convID, userID)
	return err
}
