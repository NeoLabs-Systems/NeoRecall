package memories

import (
	"context"
	"math"
	"sort"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

type DedupeResult struct {
	Judged int `json:"judged"`
	Merged int `json:"merged"`
}

func (s *Service) SweepDuplicates(ctx context.Context, userID string, proc processing.Settings) (DedupeResult, error) {
	var res DedupeResult
	if !proc.MemoryDedupeEnabled || s.AI == nil || !s.AI.Ready(ctx) {
		return res, nil
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT m.id, m.public_id, m.type, m.title_en, m.summary_en, m.started_at, m.ended_at,
		se.model_revision, se.embedding
		FROM memories m
		JOIN search_documents sd ON sd.user_id=m.user_id AND sd.kind='memory' AND sd.source_id=CAST(m.id AS TEXT)
		JOIN search_embeddings se ON se.document_id=sd.id
		WHERE m.user_id=? AND m.archived=0 AND m.dedupe_checked_at IS NULL
		ORDER BY m.started_at ASC`, userID)
	if err != nil {
		return res, err
	}
	type cand struct {
		id      int64
		pubID   string
		typ     string
		title   string
		summary string
		started string
		ended   string
		rev     string
		vec     []float32
	}
	var pending []cand
	for rows.Next() {
		var c cand
		var blob []byte
		if rows.Scan(&c.id, &c.pubID, &c.typ, &c.title, &c.summary, &c.started, &c.ended, &c.rev, &blob) == nil {
			c.vec = transcription.VectorFromBytes(blob)
			if len(c.vec) > 0 {
				pending = append(pending, c)
			}
		}
	}
	rows.Close()

	asked := make(map[string]bool)
	var checked []int64
	markChecked := func() {
		if len(checked) == 0 {
			return
		}
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE memories SET dedupe_checked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
			WHERE id IN (`+placeholders(len(checked))+`)`, anyInts(checked)...)
		checked = nil
	}
	defer markChecked()

	maxPairs := max(1, proc.MemoryDedupeMaxPairsPerRun)
	maxNeigh := max(1, proc.MemoryDedupeNeighbours)

	for _, c := range pending {
		if res.Judged >= maxPairs {
			break
		}
		var exists int
		if s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM memories WHERE id=?`, c.id).Scan(&exists) != nil || exists == 0 {
			continue
		}
		tS, _ := timeutil.ParseISO(c.started)
		tE, _ := timeutil.ParseISO(c.ended)
		winLo := timeutil.FormatISO(timeutil.AddMillis(tS, -proc.MemoryDedupeWindowMs))
		winHi := timeutil.FormatISO(timeutil.AddMillis(tE, proc.MemoryDedupeWindowMs))

		nrows, err := s.DB.R.QueryContext(ctx, `SELECT m.id, m.public_id, m.type, m.title_en, m.summary_en, m.started_at, m.ended_at,
			se.model_revision, se.embedding
			FROM memories m
			JOIN search_documents sd ON sd.user_id=m.user_id AND sd.kind='memory' AND sd.source_id=CAST(m.id AS TEXT)
			JOIN search_embeddings se ON se.document_id=sd.id
			WHERE m.user_id=? AND m.archived=0 AND m.id<>? AND m.ended_at>=? AND m.started_at<=?`,
			userID, c.id, winLo, winHi)
		if err != nil {
			continue
		}
		type scored struct {
			other cand
			sim   float64
		}
		var neighs []scored
		for nrows.Next() {
			var o cand
			var blob []byte
			if nrows.Scan(&o.id, &o.pubID, &o.typ, &o.title, &o.summary, &o.started, &o.ended, &o.rev, &blob) == nil && o.rev == c.rev {
				o.vec = transcription.VectorFromBytes(blob)
				sim := transcription.Cosine(c.vec, o.vec)
				if !math.IsNaN(sim) && sim >= proc.MemoryDedupeSimilarityThreshold {
					neighs = append(neighs, scored{other: o, sim: sim})
				}
			}
		}
		nrows.Close()
		sort.Slice(neighs, func(i, j int) bool { return neighs[i].sim > neighs[j].sim })
		if len(neighs) > maxNeigh {
			neighs = neighs[:maxNeigh]
		}

		absorbed := false
		for _, n := range neighs {
			if res.Judged >= maxPairs {
				break
			}
			key := c.pubID + "\x00" + n.other.pubID
			if n.other.pubID < c.pubID {
				key = n.other.pubID + "\x00" + c.pubID
			}
			if asked[key] {
				continue
			}
			asked[key] = true
			res.Judged++
			mins := minutesGap(c.started, c.ended, n.other.started, n.other.ended)
			sameSt := s.sharesStream(ctx, c.id, n.other.id)
			out, _, jerr := s.AI.JudgeDuplicateMemories(ctx, userID,
				ai.MemoryMergeInput{Type: c.typ, TitleEn: c.title, SummaryEn: c.summary, StartedAt: c.started, EndedAt: c.ended},
				ai.MemoryMergeInput{Type: n.other.typ, TitleEn: n.other.title, SummaryEn: n.other.summary, StartedAt: n.other.started, EndedAt: n.other.ended},
				mins, sameSt)
			if jerr != nil {
				return res, nil // preserve checked list so far; retry remaining next pass
			}
			if !out.SameOccasion {
				continue
			}
			det, _, merr := s.Merge(ctx, userID, []string{c.pubID, n.other.pubID}, true)
			if merr == nil {
				res.Merged++
				absorbed = true
				_, _ = s.DB.W.ExecContext(ctx, `UPDATE memories SET dedupe_checked_at=NULL WHERE public_id=? AND user_id=?`, det.PublicID, userID)
				break
			}
		}
		if !absorbed {
			checked = append(checked, c.id)
		}
	}
	return res, nil
}

func minutesGap(s1, e1, s2, e2 string) int {
	ts1, _ := timeutil.ParseISO(s1)
	te1, _ := timeutil.ParseISO(e1)
	ts2, _ := timeutil.ParseISO(s2)
	te2, _ := timeutil.ParseISO(e2)
	if !te1.Before(ts2) && !te2.Before(ts1) {
		return 0
	}
	gap := ts2.Sub(te1)
	if gap < 0 {
		gap = ts1.Sub(te2)
	}
	return max(0, int(math.Round(gap.Minutes())))
}

func (s *Service) sharesStream(ctx context.Context, m1, m2 int64) bool {
	var cnt int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM memory_sources s1
		JOIN transcript_segments ts1 ON (ts1.id=s1.segment_id OR ts1.conversation_id=s1.conversation_id)
		JOIN audio_chunks ac1 ON ac1.id=ts1.chunk_id
		WHERE s1.memory_id=? AND EXISTS (
			SELECT 1 FROM memory_sources s2
			JOIN transcript_segments ts2 ON (ts2.id=s2.segment_id OR ts2.conversation_id=s2.conversation_id)
			JOIN audio_chunks ac2 ON ac2.id=ts2.chunk_id
			WHERE s2.memory_id=? AND ac2.session_id=ac1.session_id
		)`, m1, m2).Scan(&cnt)
	return cnt > 0
}

var _ = time.Minute
