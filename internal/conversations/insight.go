package conversations

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

const (
	InsightNone        = "none"
	InsightProvisional = "provisional"
	InsightFinal       = "final"
)

var PreviewableStates = []string{"open", "closed"}

type PreviewAI interface {
	Ready(ctx context.Context) bool
	PreviewConversation(ctx context.Context, userID string, conv ai.InputConversation, prev *ai.PreviewOutput, tz string) (ai.PreviewOutput, string, error)
}

type InsightService struct {
	DB       *dbx.DB
	Cfg      func() config.Config
	Context  *nctx.Service
	Jobs     *jobs.Service
	Settings *settings.Service
	Usage    *usage.Service
	AI       PreviewAI
	Log      *slog.Logger
}

func (s *InsightService) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

type Thresholds struct {
	Enabled          bool
	MinCharacters    int
	RefreshChars     int
	MinIntervalMs    int64
	FullCharacters   int
	BudgetCharacters int
}

func (s *InsightService) Thresholds(ctx context.Context) Thresholds {
	c := s.cfg()
	promptToks := max(1, c.LLMContextSize-c.AIPreviewMaxOutTokens-config.LLMPromptReserveTokens)
	return Thresholds{
		Enabled:          s.AI != nil && s.AI.Ready(ctx),
		MinCharacters:    c.ConversationPreviewMinCharacters,
		RefreshChars:     c.ConversationPreviewRefreshChars,
		MinIntervalMs:    c.ConversationPreviewMinIntervalMs,
		FullCharacters:   c.ConversationPreviewFullCharacters,
		BudgetCharacters: promptToks * 3,
	}
}

func PreviewOwns(c ConversationRow) bool {
	return c.InsightState != InsightFinal
}

func (s *InsightService) hasContextSince(ctx context.Context, userID string, c ConversationRow, since string) bool {
	if s.Context == nil || c.SessionID == nil || *c.SessionID == "" || since == "" {
		return false
	}
	return s.Context.HasSince(ctx, userID, *c.SessionID, c.StartedAt, c.EndedAt, since)
}

func PreviewDue(c ConversationRow, chars int, lim Thresholds, nowMs int64, contextRefresh bool) bool {
	if !PreviewOwns(c) {
		return false
	}
	if chars < lim.MinCharacters {
		return false
	}
	lastStamp := c.InsightAttemptedAt
	if c.InsightUpdatedAt != nil {
		lastStamp = c.InsightUpdatedAt
	}
	if lastStamp == nil || *lastStamp == "" {
		return true
	}
	lastT, err := timeutil.ParseISO(*lastStamp)
	if err == nil && nowMs-lastT.UnixMilli() < lim.MinIntervalMs {
		return false
	}
	if contextRefresh {
		return true
	}
	return chars-c.InsightCharacters >= lim.RefreshChars
}

func (s *InsightService) Due(ctx context.Context, userID string) ([]ConversationRow, error) {
	if s.Usage != nil {
		if snap, err := s.Usage.GetUsageSnapshot(ctx, userID, false); err == nil && (snap.AI.Reached.FourHour || snap.AI.Reached.Weekly) {
			return nil, nil
		}
	}
	lim := s.Thresholds(ctx)
	if !lim.Enabled {
		return nil, nil
	}
	convs, err := ListByState(ctx, s.DB.R, userID, PreviewableStates, true)
	if err != nil {
		return nil, err
	}
	nowMs := time.Now().UTC().UnixMilli()
	var due []ConversationRow
	for _, c := range convs {
		if !PreviewOwns(c) {
			continue
		}
		chars := TranscriptCharacters(ctx, s.DB.R, userID, c.ID)
		ref := c.InsightAttemptedAt
		if c.InsightUpdatedAt != nil {
			ref = c.InsightUpdatedAt
		}
		refStr := ""
		if ref != nil {
			refStr = *ref
		}
		if !PreviewDue(c, chars, lim, nowMs, s.hasContextSince(ctx, userID, c, refStr)) {
			continue
		}
		if IsComplete(ctx, s.DB.R, userID, c.ID) {
			due = append(due, c)
		}
	}
	return due, nil
}

func (s *InsightService) EnqueuePreview(ctx context.Context, userID, convID string) error {
	if s.Jobs == nil {
		return nil
	}
	_, err := s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
		UserID: userID, ResourceType: "conversation", ResourceID: convID,
		Type: "preview_conversation", Priority: 40,
		Payload: map[string]any{"conversationId": convID},
	})
	return err
}

func (s *InsightService) Request(ctx context.Context, userID string) ([]string, error) {
	due, err := s.Due(ctx, userID)
	if err != nil {
		return nil, err
	}
	var queued []string
	for _, c := range due {
		_ = s.EnqueuePreview(ctx, userID, c.ID)
		queued = append(queued, c.ID)
	}
	return queued, nil
}

func (s *InsightService) EnqueueForSession(ctx context.Context, userID, sessionID string) []string {
	if sessionID == "" {
		return nil
	}
	if s.Usage != nil {
		if snap, err := s.Usage.GetUsageSnapshot(ctx, userID, false); err == nil && (snap.AI.Reached.FourHour || snap.AI.Reached.Weekly) {
			return nil
		}
	}
	convs, err := ListForSession(ctx, s.DB.R, userID, sessionID)
	if err != nil {
		return nil
	}
	var queued []string
	for _, c := range convs {
		if !PreviewOwns(c) || c.InsightState == InsightFinal {
			continue
		}
		_ = s.EnqueuePreview(ctx, userID, c.ID)
		queued = append(queued, c.ID)
	}
	return queued
}

func fitToBudget(segs []ai.InputSegment, budgetChars int) []ai.InputSegment {
	var out []ai.InputSegment
	used := 0
	for _, s := range segs {
		sz := len(s.Text)
		if len(out) > 0 && used+sz > budgetChars {
			break
		}
		out = append(out, s)
		used += sz
	}
	return out
}

func describedChars(all, sent []ai.InputSegment) int {
	if len(sent) == 0 {
		return 0
	}
	lastID := sent[len(sent)-1].ID
	total := 0
	for _, s := range all {
		total += len(s.Text)
		if s.ID == lastID {
			break
		}
	}
	return total
}

func (s *InsightService) Execute(ctx context.Context, userID, convID string) (map[string]any, error) {
	lim := s.Thresholds(ctx)
	if !lim.Enabled {
		return map[string]any{"skipped": "ai_not_configured"}, nil
	}
	conv, err := FindInState(ctx, s.DB.R, userID, convID, PreviewableStates, true)
	if err != nil {
		return nil, err
	}
	if conv == nil || !PreviewOwns(*conv) {
		return map[string]any{"skipped": "not_previewable"}, nil
	}
	ref := conv.InsightAttemptedAt
	if conv.InsightUpdatedAt != nil {
		ref = conv.InsightUpdatedAt
	}
	refStr := ""
	if ref != nil {
		refStr = *ref
	}
	chars := TranscriptCharacters(ctx, s.DB.R, userID, convID)
	if !PreviewDue(*conv, chars, lim, time.Now().UTC().UnixMilli(), s.hasContextSince(ctx, userID, *conv, refStr)) {
		return map[string]any{"skipped": "not_due"}, nil
	}
	if !IsComplete(ctx, s.DB.R, userID, convID) {
		return map[string]any{"skipped": "incomplete"}, nil
	}

	mat, totalChars, err := BuildMaterial(ctx, s.DB.R, userID, *conv, s.Context)
	if err != nil {
		return nil, err
	}
	rolling := conv.InsightState == InsightProvisional &&
		conv.InsightCoveredThrough != nil && *conv.InsightCoveredThrough != "" &&
		conv.TitleEn != nil && conv.SummaryEn != nil &&
		totalChars > lim.FullCharacters

	var fresh []ai.InputSegment
	if rolling {
		rows, _ := SegmentsAfter(ctx, s.DB.R, userID, conv.ID, *conv.InsightCoveredThrough)
		for _, r := range rows {
			fresh = append(fresh, ai.InputSegment{
				ID: r.PublicID, StartedAt: r.StartedAt, EndedAt: r.EndedAt,
				Text: r.Text, Language: r.Language, SpeakerClusterID: r.SpeakerClusterID,
			})
		}
	}
	continuing := rolling && len(fresh) > 0 && len(fresh) != len(mat.Segments)
	cand := mat.Segments
	if continuing {
		cand = fresh
	}
	sent := fitToBudget(cand, lim.BudgetCharacters)
	matForAI := mat
	matForAI.Segments = sent

	var prevPtr *ai.PreviewOutput
	if continuing {
		prevPtr = &ai.PreviewOutput{
			TitleEn:   *conv.TitleEn,
			SummaryEn: *conv.SummaryEn,
			Topics:    conv.Topics,
		}
	}
	coveredThrough := conv.EndedAt
	if len(sent) > 0 {
		coveredThrough = sent[len(sent)-1].EndedAt
	}
	attemptedAt := refStr
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE conversations SET insight_attempted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`, convID, userID)

	tz := "UTC"
	if s.Settings != nil {
		if st, err := s.Settings.Get(ctx, userID); err == nil {
			if tzs, _ := st["timezone"].(string); tzs != "" {
				tz = tzs
			}
		}
	}
	preview, reqID, err := s.AI.PreviewConversation(ctx, userID, matForAI, prevPtr, tz)
	if err != nil {
		return nil, err
	}
	superseded, err := s.Persist(ctx, userID, convID, preview, describedChars(mat.Segments, sent), coveredThrough, reqID)
	if err != nil {
		return nil, err
	}
	if s.hasContextSince(ctx, userID, *conv, attemptedAt) {
		_ = s.EnqueuePreview(ctx, userID, convID)
	}
	return map[string]any{"conversationId": convID, "rolling": continuing, "superseded": superseded}, nil
}

func (s *InsightService) Persist(ctx context.Context, userID, convID string, prev ai.PreviewOutput, chars int, coveredThrough, aiReqID string) (bool, error) {
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	topicsJSON, _ := json.Marshal(prev.Topics)
	mw := 0
	if prev.MemoryWorthy {
		mw = 1
	}
	var reqNull any
	if aiReqID != "" {
		reqNull = aiReqID
	}
	res, err := tx.ExecContext(ctx, `UPDATE conversations SET title_en=?, summary_en=?, topics_json=?, memory_worthy=?,
		insight_state=?, insight_characters=?, insight_covered_through=?, insight_request_id=?,
		insight_updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id=? AND user_id=? AND insight_state<>?`,
		prev.TitleEn, prev.SummaryEn, string(topicsJSON), mw,
		InsightProvisional, chars, coveredThrough, reqNull, convID, userID, InsightFinal)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return true, nil
	}
	_ = events.EmitExec(ctx, tx, userID, "conversation.insight", "conversation", convID, map[string]any{
		"conversationId": convID,
		"insightState":   InsightProvisional,
		"titleEn":        prev.TitleEn,
		"memoryWorthy":   prev.MemoryWorthy,
	})
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return false, nil
}
