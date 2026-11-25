package conversations

import (
	"context"
	"math"
	"sort"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/google/uuid"
)

type BoundarySegment struct {
	PublicID  string
	StartedAt string
	EndedAt   string
	Text      string
	Embedding []float32
}

// ComputeSplits finds boundary indices (1..len-1) where a conversation should split based on gaps, semantic valleys, or max bounds.
func ComputeSplits(segs []BoundarySegment, cfg config.Config) []int {
	if len(segs) <= 1 {
		return nil
	}
	hardGap := cfg.ConversationHardGapMs
	if hardGap <= 0 {
		hardGap = 600_000
	}
	softGap := cfg.ConversationSoftGapMs
	if softGap <= 0 {
		softGap = 300_000
	}
	minMs := cfg.ConversationMinimumMs
	if minMs <= 0 {
		minMs = 300_000
	}
	maxMs := cfg.ConversationMaximumMs
	if maxMs <= 0 {
		maxMs = 4 * 60 * 60_000
	}
	maxChars := cfg.ConversationMaximumCharacters
	if maxChars <= 0 {
		maxChars = 200_000
	}

	sims := make([]float64, len(segs)-1)
	var validSims []float64
	hasEmb := true
	for i := 0; i < len(segs)-1; i++ {
		if len(segs[i].Embedding) == 0 || len(segs[i+1].Embedding) == 0 {
			hasEmb = false
			break
		}
		sim := transcription.Cosine(segs[i].Embedding, segs[i+1].Embedding)
		sims[i] = sim
		validSims = append(validSims, sim)
	}
	var valleyCutoff float64 = cfg.ConversationSemanticSimilarityThr
	if hasEmb && len(validSims) >= 4 {
		sorted := append([]float64(nil), validSims...)
		sort.Float64s(sorted)
		idx := int(math.Floor(cfg.ConversationValleyQuantile * float64(len(sorted)-1)))
		if idx >= 0 && idx < len(sorted) && sorted[idx] < valleyCutoff {
			valleyCutoff = sorted[idx]
		}
	}

	var splits []int
	segStartIdx := 0
	accChars := len(segs[0].Text)
	for i := 1; i < len(segs); i++ {
		gap := DurationMs(segs[i-1].EndedAt, segs[i].StartedAt)
		curDur := DurationMs(segs[segStartIdx].StartedAt, segs[i].EndedAt)
		nextChars := accChars + len(segs[i].Text)

		split := false
		if gap >= hardGap || curDur >= maxMs || nextChars > maxChars {
			split = true
		} else if gap >= softGap && DurationMs(segs[segStartIdx].StartedAt, segs[i-1].EndedAt) >= minMs {
			split = true
		} else if hasEmb && DurationMs(segs[segStartIdx].StartedAt, segs[i-1].EndedAt) >= minMs {
			s := sims[i-1]
			if s <= valleyCutoff {
				left := s
				if i-2 >= 0 {
					left = sims[i-2]
				}
				right := s
				if i < len(sims) {
					right = sims[i]
				}
				if math.Min(left-s, right-s) >= cfg.ConversationSemanticValleyProminence {
					split = true
				}
			}
		}
		if split {
			splits = append(splits, i)
			segStartIdx = i
			accChars = len(segs[i].Text)
		} else {
			accChars = nextChars
		}
	}
	return splits
}

// ReevaluateConversation splits an unrefined conversation if boundary heuristics detect distinct sub-conversations.
func ReevaluateConversation(ctx context.Context, db *dbx.DB, emb *embeddings.Service, cfg config.Config, userID, convID string) (bool, error) {
	conv, err := FindInState(ctx, db.R, userID, convID, []string{"open", "closed"}, true)
	if err != nil || conv == nil || conv.RefinedAt != nil {
		return false, err
	}
	segs, err := SegmentsOf(ctx, db.R, userID, convID)
	if err != nil || len(segs) < 2 {
		return false, err
	}
	bSegs := make([]BoundarySegment, len(segs))
	win := max(1, cfg.ConversationSemanticContextSegments)
	canEmbed := emb != nil && emb.VectorReady()
	for i, s := range segs {
		bs := BoundarySegment{PublicID: s.PublicID, StartedAt: s.StartedAt, EndedAt: s.EndedAt, Text: s.Text}
		if canEmbed && len(segs) <= 120 {
			lo := max(0, i-win+1)
			txt := ""
			for j := lo; j <= i; j++ {
				if j > lo {
					txt += " "
				}
				txt += segs[j].Text
			}
			if v, err := emb.Embed(ctx, txt, "passage"); err == nil {
				bs.Embedding = v
			}
		}
		bSegs[i] = bs
	}
	splits := ComputeSplits(bSegs, cfg)
	if len(splits) == 0 {
		return false, nil
	}

	tx, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	bounds := append([]int{0}, splits...)
	bounds = append(bounds, len(segs))
	for k := 0; k < len(bounds)-1; k++ {
		chunk := segs[bounds[k]:bounds[k+1]]
		if len(chunk) == 0 {
			continue
		}
		targetID := convID
		if k > 0 {
			targetID = uuid.NewString()
			state := "closed"
			if k == len(bounds)-2 && conv.State == "open" {
				state = "open"
			}
			if _, err := tx.ExecContext(ctx, `INSERT INTO conversations
				(id, user_id, started_at, ended_at, state, boundary_method, boundary_version)
				VALUES (?, ?, ?, ?, ?, ?, ?)`,
				targetID, userID, chunk[0].StartedAt, chunk[len(chunk)-1].EndedAt, state, BoundaryMethod, BoundaryVersion); err != nil {
				return false, err
			}
		} else {
			if _, err := tx.ExecContext(ctx, `UPDATE conversations SET state='closed' WHERE id=? AND user_id=?`, targetID, userID); err != nil {
				return false, err
			}
		}
		pubIDs := make([]string, len(chunk))
		for i, c := range chunk {
			pubIDs[i] = c.PublicID
		}
		if err := AssignSegments(ctx, tx, userID, targetID, pubIDs, true); err != nil {
			return false, err
		}
		_ = speakers.RebuildConversationSpeakers(ctx, tx, userID, targetID)
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}
