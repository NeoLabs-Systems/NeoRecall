package memories

import (
	"context"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type OccasionReadiness struct {
	Ready            bool
	Reason           string
	ConsolidateAfter *string
}

func ReceivingAudio(ctx context.Context, q conversations.Queryer, userID, sessionID, quietSinceISO string) bool {
	if sessionID == "" {
		return false
	}
	var status string
	if err := q.QueryRowContext(ctx, `SELECT status FROM recording_sessions WHERE id=? AND user_id=?`, sessionID, userID).Scan(&status); err == nil && status == "active" {
		var openCnt int
		_ = q.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations c
			JOIN transcript_segments ts ON ts.conversation_id=c.id
			JOIN audio_chunks ac ON ac.id=ts.chunk_id
			WHERE c.user_id=? AND ac.session_id=? AND c.state='open'`, userID, sessionID).Scan(&openCnt)
		if openCnt > 0 {
			return true
		}
	}
	var recent int
	_ = q.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks WHERE user_id=? AND session_id=? AND created_at>=?`,
		userID, sessionID, quietSinceISO).Scan(&recent)
	return recent > 0
}

func OccasionChain(convs []conversations.ConversationRow, startIdx int, gapMs int64) []conversations.ConversationRow {
	if startIdx < 0 || startIdx >= len(convs) {
		return nil
	}
	chain := []conversations.ConversationRow{convs[startIdx]}
	lastEnd := convs[startIdx].EndedAt
	var sess string
	if convs[startIdx].SessionID != nil {
		sess = *convs[startIdx].SessionID
	}
	for i := startIdx + 1; i < len(convs); i++ {
		c := convs[i]
		cSess := ""
		if c.SessionID != nil {
			cSess = *c.SessionID
		}
		if sess == "" || cSess != sess {
			break
		}
		if conversations.DurationMs(lastEnd, c.StartedAt) > gapMs {
			break
		}
		chain = append(chain, c)
		if c.EndedAt > lastEnd {
			lastEnd = c.EndedAt
		}
	}
	return chain
}

func HasOpenAfterInChain(ctx context.Context, q conversations.Queryer, userID, sessionID, endedAt string, cfg config.Config) bool {
	if sessionID == "" {
		return false
	}
	openConvs, err := conversations.ListByState(ctx, q, userID, []string{"open"}, true)
	if err != nil {
		return false
	}
	for _, c := range openConvs {
		if c.SessionID != nil && *c.SessionID == sessionID && conversations.DurationMs(endedAt, c.StartedAt) <= cfg.MemoryOccasionGapMs {
			return true
		}
	}
	return false
}

func CheckOccasionReadiness(ctx context.Context, q conversations.Queryer, cfg config.Config, userID string, chain []conversations.ConversationRow, now time.Time) OccasionReadiness {
	if len(chain) == 0 {
		return OccasionReadiness{Ready: false, Reason: "empty"}
	}
	first := chain[0]
	last := chain[len(chain)-1]
	var sess string
	if first.SessionID != nil {
		sess = *first.SessionID
	}
	if HasOpenAfterInChain(ctx, q, userID, sess, last.EndedAt, cfg) {
		after := timeutil.FormatISO(timeutil.AddMillis(now, cfg.MemorySettleMs))
		return OccasionReadiness{Ready: false, Reason: "open_in_occasion", ConsolidateAfter: &after}
	}
	heldSinceT, err := timeutil.ParseISO(first.EndedAt)
	if err != nil {
		return OccasionReadiness{Ready: true, Reason: "settled"}
	}
	if now.Sub(heldSinceT).Milliseconds() >= cfg.MemoryOccasionMaxWaitMs {
		return OccasionReadiness{Ready: true, Reason: "max_wait"}
	}
	quietSince := timeutil.FormatISO(timeutil.AddMillis(now, -cfg.MemorySettleMs))
	if !ReceivingAudio(ctx, q, userID, sess, quietSince) {
		return OccasionReadiness{Ready: true, Reason: "recording_stopped"}
	}
	lastEndT, err := timeutil.ParseISO(last.EndedAt)
	if err != nil {
		return OccasionReadiness{Ready: true, Reason: "settled"}
	}
	settledAt := timeutil.AddMillis(lastEndT, cfg.MemorySettleMs)
	if !now.Before(settledAt) {
		return OccasionReadiness{Ready: true, Reason: "settled"}
	}
	capAt := timeutil.AddMillis(heldSinceT, cfg.MemoryOccasionMaxWaitMs)
	target := settledAt
	if capAt.Before(target) {
		target = capAt
	}
	iso := timeutil.FormatISO(target)
	return OccasionReadiness{Ready: false, Reason: "occasion_unsettled", ConsolidateAfter: &iso}
}
