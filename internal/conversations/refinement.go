package conversations

import (
	"fmt"
	"slices"
	"sort"
	"strings"

	"context"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/google/uuid"
)

const (
	RefinementMethod  = "time-context-embedding+llm-topic"
	RefinementVersion = "3"
)

type streamSeg struct {
	Seg                    ai.InputSegment
	originalConversationID string
	streamID               string
}

type RefinedConversation struct {
	ID                   string
	OriginConversationID string
	StartedAt            string
	EndedAt              string
	TitleEn              string
	SummaryEn            string
	MemoryWorthy         bool
	ContinuesPrevious    bool
	Topics               []string
	Segments             []streamSeg
}

type RefinementPlanResult struct {
	Conversations         []RefinedConversation
	SegmentConversationID map[string]string
}

func refErr(msg string) error {
	return &ai.AIError{Code: "AI_REFERENCE_INVALID", Message: msg}
}

func orderedStreamSegments(conversations []ai.InputConversation) (map[string][]streamSeg, []string) {
	streams := make(map[string][]streamSeg)
	var streamOrder []string
	for _, conv := range conversations {
		streamID := conv.ID
		if conv.SessionID != nil && *conv.SessionID != "" {
			streamID = *conv.SessionID
		}
		if _, ok := streams[streamID]; !ok {
			streamOrder = append(streamOrder, streamID)
		}
		for _, s := range conv.Segments {
			streams[streamID] = append(streams[streamID], streamSeg{
				Seg:                    s,
				originalConversationID: conv.ID,
				streamID:               streamID,
			})
		}
	}
	for _, sid := range streamOrder {
		segs := streams[sid]
		sort.Slice(segs, func(i, j int) bool {
			if segs[i].Seg.StartedAt != segs[j].Seg.StartedAt {
				return segs[i].Seg.StartedAt < segs[j].Seg.StartedAt
			}
			if segs[i].Seg.EndedAt != segs[j].Seg.EndedAt {
				return segs[i].Seg.EndedAt < segs[j].Seg.EndedAt
			}
			return segs[i].Seg.ID < segs[j].Seg.ID
		})
	}
	return streams, streamOrder
}

type indexedSeg struct {
	streamID string
	index    int
	seg      streamSeg
}

type validatedSection struct {
	ai.ConversationSection
	outputIndex int
	streamID    string
	startIndex  int
	endIndex    int
	segments    []streamSeg
}

func ValidateConversationSections(sections []ai.ConversationSection, conversations []ai.InputConversation) ([]validatedSection, error) {
	if len(sections) == 0 {
		return nil, refErr("Conversation refinement must produce at least one section.")
	}
	streams, streamOrder := orderedStreamSegments(conversations)
	segIdx := make(map[string]indexedSeg)
	for _, sid := range streamOrder {
		for idx, sm := range streams[sid] {
			segIdx[sm.Seg.ID] = indexedSeg{streamID: sid, index: idx, seg: sm}
		}
	}

	rangesByStream := make(map[string][]validatedSection)
	seen := make(map[string]bool)
	normalized := make([]validatedSection, 0, len(sections))

	for outIdx, sec := range sections {
		if len(sec.SourceSegmentIDs) == 0 {
			return nil, refErr("A conversation section had no segments.")
		}
		refs := make([]indexedSeg, 0, len(sec.SourceSegmentIDs))
		for _, id := range sec.SourceSegmentIDs {
			r, ok := segIdx[id]
			if !ok {
				return nil, refErr("A conversation section cited a segment outside the consolidation input.")
			}
			if seen[id] {
				return nil, refErr("A transcript segment appeared in more than one conversation section.")
			}
			seen[id] = true
			refs = append(refs, r)
		}
		sid := refs[0].streamID
		for i := 1; i < len(refs); i++ {
			if refs[i].streamID != sid {
				return nil, refErr("A conversation section mixed independent recording streams.")
			}
			if refs[i].index != refs[i-1].index+1 {
				return nil, refErr("Conversation section segments must be contiguous and chronological.")
			}
		}
		segs := make([]streamSeg, len(refs))
		for i, r := range refs {
			segs[i] = r.seg
		}
		vs := validatedSection{
			ConversationSection: sec,
			outputIndex:         outIdx,
			streamID:            sid,
			startIndex:          refs[0].index,
			endIndex:            refs[len(refs)-1].index,
			segments:            segs,
		}
		rangesByStream[sid] = append(rangesByStream[sid], vs)
		normalized = append(normalized, vs)
	}

	for _, sid := range streamOrder {
		ranges := slices.Clone(rangesByStream[sid])
		sort.Slice(ranges, func(i, j int) bool { return ranges[i].startIndex < ranges[j].startIndex })
		expected := 0
		for _, rg := range ranges {
			if rg.startIndex != expected {
				return nil, refErr("Conversation sections must cover each recording stream without gaps or overlaps.")
			}
			expected = rg.endIndex + 1
		}
		if expected != len(streams[sid]) {
			return nil, refErr("Conversation sections omitted transcript segments.")
		}
	}
	if len(seen) != len(segIdx) {
		return nil, refErr("Conversation sections omitted transcript segments.")
	}
	sort.Slice(normalized, func(i, j int) bool {
		if normalized[i].segments[0].Seg.StartedAt != normalized[j].segments[0].Seg.StartedAt {
			return normalized[i].segments[0].Seg.StartedAt < normalized[j].segments[0].Seg.StartedAt
		}
		return normalized[i].outputIndex < normalized[j].outputIndex
	})
	return normalized, nil
}

func normalizedTopics(topics []string) []string {
	seen := make(map[string]bool)
	out := []string{}
	for _, t := range topics {
		tr := strings.TrimSpace(t)
		key := strings.ToLower(tr)
		if tr == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, tr)
	}
	return out
}

func ApplyConversationSectionsTx(ctx context.Context, tx speakers.SQLExecQueryer, userID, runID string, sections []ai.ConversationSection, conversations []ai.InputConversation) (RefinementPlanResult, error) {
	validated, err := ValidateConversationSections(sections, conversations)
	if err != nil {
		return RefinementPlanResult{}, err
	}
	origIDs := make(map[string]bool, len(conversations))
	for _, c := range conversations {
		origIDs[c.ID] = true
	}
	retained := make(map[string]bool)
	plans := make([]RefinedConversation, 0, len(validated))

	for _, sec := range validated {
		prefID := sec.segments[0].originalConversationID
		id := uuid.NewString()
		if origIDs[prefID] && !retained[prefID] {
			id = prefID
			retained[id] = true
		}
		plans = append(plans, RefinedConversation{
			ID:                   id,
			OriginConversationID: prefID,
			StartedAt:            sec.segments[0].Seg.StartedAt,
			EndedAt:              sec.segments[len(sec.segments)-1].Seg.EndedAt,
			TitleEn:              sec.TitleEn,
			SummaryEn:            sec.SummaryEn,
			MemoryWorthy:         sec.MemoryWorthy,
			ContinuesPrevious:    sec.ContinuesPrevious,
			Topics:               normalizedTopics(sec.Topics),
			Segments:             sec.segments,
		})
	}

	for _, p := range plans {
		state := "not_memory_worthy"
		mw := 0
		if p.MemoryWorthy {
			state = "consolidated"
			mw = 1
		}
		chars := 0
		segIDs := make([]string, len(p.Segments))
		for i, s := range p.Segments {
			chars += len(s.Seg.Text)
			segIDs[i] = s.Seg.ID
		}
		topicsJSON := fmt.Sprintf("[%s]", "") // encode below
		if len(p.Topics) > 0 {
			quoted := make([]string, len(p.Topics))
			for i, t := range p.Topics {
				quoted[i] = `"` + strings.ReplaceAll(strings.ReplaceAll(t, `\`, `\\`), `"`, `\"`) + `"`
			}
			topicsJSON = "[" + strings.Join(quoted, ",") + "]"
		} else {
			topicsJSON = "[]"
		}

		if origIDs[p.ID] {
			res, err := tx.ExecContext(ctx, `UPDATE conversations SET
				started_at=?, ended_at=?, state=?, boundary_method=?, boundary_score=NULL, boundary_version=?,
				title_en=?, summary_en=?, topics_json=?, memory_worthy=?, insight_state='final', insight_characters=?,
				insight_updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), refined_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
				refinement_run_id=?, origin_conversation_id=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
				WHERE id=? AND user_id=?`,
				p.StartedAt, p.EndedAt, state, RefinementMethod, RefinementVersion,
				p.TitleEn, p.SummaryEn, topicsJSON, mw, chars, runID, p.OriginConversationID, p.ID, userID)
			if err != nil {
				return RefinementPlanResult{}, err
			}
			if n, _ := res.RowsAffected(); n != 1 {
				return RefinementPlanResult{}, refErr("A provisional conversation disappeared during refinement.")
			}
		} else {
			if _, err := tx.ExecContext(ctx, `INSERT INTO conversations
				(id, user_id, started_at, ended_at, state, boundary_method, boundary_score, boundary_version,
				 title_en, summary_en, topics_json, memory_worthy, insight_state, insight_characters, insight_updated_at,
				 refined_at, refinement_run_id, origin_conversation_id)
				VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, 'final', ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'),
				 strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?, ?)`,
				p.ID, userID, p.StartedAt, p.EndedAt, state, RefinementMethod, RefinementVersion,
				p.TitleEn, p.SummaryEn, topicsJSON, mw, chars, runID, p.OriginConversationID); err != nil {
				return RefinementPlanResult{}, err
			}
		}
		if err := AssignSegments(ctx, tx, userID, p.ID, segIDs, true); err != nil {
			return RefinementPlanResult{}, err
		}
	}

	for origID := range origIDs {
		if !retained[origID] {
			if _, err := tx.ExecContext(ctx, `DELETE FROM conversations WHERE id=? AND user_id=?`, origID, userID); err != nil {
				return RefinementPlanResult{}, err
			}
		}
	}
	for _, p := range plans {
		_ = speakers.RebuildConversationSpeakers(ctx, tx, userID, p.ID)
	}
	segMap := make(map[string]string)
	for _, p := range plans {
		for _, s := range p.Segments {
			segMap[s.Seg.ID] = p.ID
		}
	}
	return RefinementPlanResult{Conversations: plans, SegmentConversationID: segMap}, nil
}
