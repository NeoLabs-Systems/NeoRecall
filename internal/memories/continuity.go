package memories

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

func SourceSpeakerIdentities(ctx context.Context, q conversations.Queryer, userID string, convs []ai.InputConversation) map[string][]string {
	convIDs := make([]string, 0, len(convs))
	for _, c := range convs {
		convIDs = append(convIDs, c.ID)
	}
	if len(convIDs) == 0 {
		return nil
	}
	args := make([]any, 0, 1+len(convIDs))
	args = append(args, userID)
	for _, id := range convIDs {
		args = append(args, id)
	}
	rows, err := q.QueryContext(ctx, `SELECT ts.conversation_id, COALESCE(v.display_name, v.external_key)
		FROM transcript_segments ts
		JOIN speaker_clusters sc ON sc.id=ts.speaker_cluster_id
		JOIN voiceprints v ON v.id=sc.voiceprint_id
		WHERE ts.user_id=? AND ts.conversation_id IN (`+placeholders(len(convIDs))+`)
		  AND COALESCE(v.display_name, v.external_key) IS NOT NULL
		ORDER BY ts.started_at`, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := make(map[string][]string)
	seen := make(map[string]map[string]bool)
	for rows.Next() {
		var cid, name string
		if rows.Scan(&cid, &name) == nil && name != "" {
			if seen[cid] == nil {
				seen[cid] = make(map[string]bool)
			}
			if !seen[cid][name] {
				seen[cid][name] = true
				out[cid] = append(out[cid], name)
			}
		}
	}
	return out
}

func FindCandidates(ctx context.Context, q conversations.Queryer, userID string, convs []ai.InputConversation, cfg config.Config) []ai.ContinuationCandidate {
	lim := cfg.MaxMemoryContinuationCands
	if lim <= 0 || len(convs) == 0 {
		return nil
	}
	earliest := convs[0].StartedAt
	latest := convs[len(convs)-1].EndedAt
	for _, c := range convs {
		if c.StartedAt < earliest {
			earliest = c.StartedAt
		}
		if c.EndedAt > latest {
			latest = c.EndedAt
		}
	}
	tEarliest, err := timeutil.ParseISO(earliest)
	if err != nil {
		return nil
	}
	cutoff := timeutil.FormatISO(timeutil.AddMillis(tEarliest, -cfg.MemoryContinuationLookbackMs))

	sessSet := make(map[string]bool)
	var sessList []string
	for _, c := range convs {
		if c.SessionID != nil && *c.SessionID != "" && !sessSet[*c.SessionID] {
			sessSet[*c.SessionID] = true
			sessList = append(sessList, *c.SessionID)
		}
	}

	type rawMem struct {
		id        int64
		publicID  string
		typ       string
		titleEn   string
		summaryEn string
		startedAt string
		endedAt   string
	}
	byID := make(map[int64]rawMem)
	rows, err := q.QueryContext(ctx, `SELECT id, public_id, type, title_en, summary_en, started_at, ended_at
		FROM memories WHERE user_id=? AND archived=0 AND ended_at>=? AND started_at<=?
		ORDER BY ended_at DESC LIMIT ?`, userID, cutoff, latest, lim*2)
	if err == nil {
		for rows.Next() {
			var r rawMem
			if rows.Scan(&r.id, &r.publicID, &r.typ, &r.titleEn, &r.summaryEn, &r.startedAt, &r.endedAt) == nil {
				byID[r.id] = r
			}
		}
		rows.Close()
	}
	if len(sessList) > 0 {
		args := []any{userID}
		for _, sid := range sessList {
			args = append(args, sid)
		}
		args = append(args, lim*2)
		srows, err := q.QueryContext(ctx, `SELECT DISTINCT m.id, m.public_id, m.type, m.title_en, m.summary_en, m.started_at, m.ended_at
			FROM memories m
			JOIN memory_sources ms ON ms.memory_id=m.id
			JOIN transcript_segments ts ON (ts.id=ms.segment_id OR ts.conversation_id=ms.conversation_id)
			JOIN audio_chunks ac ON ac.id=ts.chunk_id
			WHERE m.user_id=? AND m.archived=0 AND ac.session_id IN (`+placeholders(len(sessList))+`)
			ORDER BY m.ended_at DESC LIMIT ?`, args...)
		if err == nil {
			for srows.Next() {
				var r rawMem
				if srows.Scan(&r.id, &r.publicID, &r.typ, &r.titleEn, &r.summaryEn, &r.startedAt, &r.endedAt) == nil {
					byID[r.id] = r
				}
			}
			srows.Close()
		}
	}
	if len(byID) == 0 {
		return nil
	}

	var list []rawMem
	for _, r := range byID {
		list = append(list, r)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].endedAt > list[j].endedAt })
	if len(list) > lim {
		list = list[:lim]
	}

	out := make([]ai.ContinuationCandidate, 0, len(list))
	for _, m := range list {
		c := ai.ContinuationCandidate{
			PublicID:  m.publicID,
			Type:      m.typ,
			TitleEn:   m.titleEn,
			SummaryEn: m.summaryEn,
			StartedAt: m.startedAt,
			EndedAt:   m.endedAt,
		}
		if trows, err := q.QueryContext(ctx, `SELECT topic FROM memory_topics WHERE memory_id=? ORDER BY topic`, m.id); err == nil {
			for trows.Next() {
				var t string
				if trows.Scan(&t) == nil {
					c.Topics = append(c.Topics, t)
				}
			}
			trows.Close()
		}
		if hrows, err := q.QueryContext(ctx, `SELECT text_en FROM mini_memories WHERE memory_id=? ORDER BY importance DESC LIMIT 4`, m.id); err == nil {
			for hrows.Next() {
				var h string
				if hrows.Scan(&h) == nil {
					c.Highlights = append(c.Highlights, h)
				}
			}
			hrows.Close()
		}
		if srows, err := q.QueryContext(ctx, `SELECT DISTINCT ac.session_id FROM memory_sources ms
			JOIN transcript_segments ts ON (ts.id=ms.segment_id OR ts.conversation_id=ms.conversation_id)
			JOIN audio_chunks ac ON ac.id=ts.chunk_id WHERE ms.memory_id=?`, m.id); err == nil {
			for srows.Next() {
				var s string
				if srows.Scan(&s) == nil {
					c.SessionIDs = append(c.SessionIDs, s)
				}
			}
			srows.Close()
		}
		out = append(out, c)
	}
	return out
}

func ResolveClaims(out *ai.ConsolidationOutput, cands []ai.ContinuationCandidate) (droppedUnknown, droppedDup int) {
	valid := make(map[string]bool, len(cands))
	for _, c := range cands {
		valid[c.PublicID] = true
	}
	claimed := make(map[string]bool)
	for i := range out.Memories {
		var kept []string
		for _, id := range out.Memories[i].ContinuesMemoryIDs {
			if !valid[id] {
				droppedUnknown++
				continue
			}
			if claimed[id] {
				droppedDup++
				continue
			}
			claimed[id] = true
			kept = append(kept, id)
		}
		out.Memories[i].ContinuesMemoryIDs = kept
	}
	return droppedUnknown, droppedDup
}

func copyRelationsTx(ctx context.Context, tx *sql.Tx, table string, cols []string, targetID, absorbedID int64) error {
	names := strings.Join(cols, ",")
	var selParts, matchParts []string
	for _, col := range cols {
		if col == "memory_id" {
			selParts = append(selParts, "?")
		} else {
			selParts = append(selParts, "source."+col)
			matchParts = append(matchParts, "existing."+col+" IS source."+col)
		}
	}
	q := `INSERT INTO ` + table + ` (` + names + `)
		SELECT ` + strings.Join(selParts, ",") + ` FROM ` + table + ` source
		WHERE source.memory_id=?
		  AND NOT EXISTS (SELECT 1 FROM ` + table + ` existing WHERE existing.memory_id=? AND ` + strings.Join(matchParts, " AND ") + `)`
	_, err := tx.ExecContext(ctx, q, targetID, absorbedID, targetID)
	return err
}

type AbsorbedResult struct {
	TargetID  int64
	PublicID  string
	StartedAt string
	EndedAt   string
	Pinned    int
	Archived  int
	Absorbed  []int64
}

func AbsorbClaimedTx(ctx context.Context, tx *sql.Tx, userID string, publicIDs []string) (*AbsorbedResult, error) {
	seen := make(map[string]bool)
	var ids []string
	for _, id := range publicIDs {
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return nil, nil
	}
	args := append([]any{userID}, anyStrings(ids)...)
	rows, err := tx.QueryContext(ctx, `SELECT id, public_id, started_at, ended_at, pinned, archived
		FROM memories WHERE user_id=? AND public_id IN (`+placeholders(len(ids))+`)`, args...)
	if err != nil {
		return nil, err
	}
	type row struct {
		id               int64
		publicID         string
		started, ended   string
		pinned, archived int
	}
	var list []row
	for rows.Next() {
		var r row
		if rows.Scan(&r.id, &r.publicID, &r.started, &r.ended, &r.pinned, &r.archived) == nil {
			list = append(list, r)
		}
	}
	rows.Close()
	if len(list) != len(ids) {
		return nil, httperr.New(http.StatusConflict, "CONSOLIDATION_INPUT_CHANGED", "A continuation candidate changed before consolidation was persisted.")
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].started != list[j].started {
			return list[i].started < list[j].started
		}
		return list[i].id < list[j].id
	})
	target := list[0]
	absorbed := list[1:]
	minStart, maxEnd := target.started, target.ended
	pinned := target.pinned
	var absorbedIDs []int64

	for _, ab := range absorbed {
		if ab.started < minStart {
			minStart = ab.started
		}
		if ab.ended > maxEnd {
			maxEnd = ab.ended
		}
		if ab.pinned == 1 {
			pinned = 1
		}
		_, _ = tx.ExecContext(ctx, `UPDATE mini_memories SET memory_id=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE memory_id=? AND user_id=?`,
			target.id, ab.id, userID)
		_ = copyRelationsTx(ctx, tx, "memory_topics", []string{"memory_id", "topic"}, target.id, ab.id)
		_ = copyRelationsTx(ctx, tx, "memory_entities", []string{"memory_id", "entity_id", "role"}, target.id, ab.id)
		_ = copyRelationsTx(ctx, tx, "memory_sources", []string{"memory_id", "conversation_id", "segment_id"}, target.id, ab.id)
		if clrows, err := tx.QueryContext(ctx, `SELECT context_item_id, used_by_ai FROM memory_context_sources WHERE memory_id=?`, ab.id); err == nil {
			type cl struct {
				id string
				u  int
			}
			var cls []cl
			for clrows.Next() {
				var x cl
				if clrows.Scan(&x.id, &x.u) == nil {
					cls = append(cls, x)
				}
			}
			clrows.Close()
			for _, x := range cls {
				_, _ = tx.ExecContext(ctx, `INSERT INTO memory_context_sources (memory_id, context_item_id, used_by_ai)
					VALUES (?, ?, ?) ON CONFLICT(memory_id, context_item_id) DO UPDATE SET used_by_ai=MAX(used_by_ai, excluded.used_by_ai)`,
					target.id, x.id, x.u)
			}
		}
		_, _ = tx.ExecContext(ctx, `UPDATE recording_context_items SET memory_id=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE memory_id=? AND user_id=?`,
			target.id, ab.id, userID)
		absorbedIDs = append(absorbedIDs, ab.id)
	}
	if len(absorbedIDs) > 0 {
		var refs []embeddings.SearchSourceRef
		for _, id := range absorbedIDs {
			refs = append(refs, embeddings.SearchSourceRef{Kind: "memory", SourceID: intStr(id)})
		}
		_, _ = embeddings.RemoveBySourcesTx(ctx, tx, userID, refs)
		for _, id := range absorbedIDs {
			_, _ = tx.ExecContext(ctx, `DELETE FROM memories WHERE id=? AND user_id=?`, id, userID)
		}
	}
	return &AbsorbedResult{
		TargetID:  target.id,
		PublicID:  target.publicID,
		StartedAt: minStart,
		EndedAt:   maxEnd,
		Pinned:    pinned,
		Archived:  target.archived,
		Absorbed:  absorbedIDs,
	}, nil
}

func anyStrings(in []string) []any {
	out := make([]any, len(in))
	for i, s := range in {
		out[i] = s
	}
	return out
}

func intStr(v int64) string {
	return formatInt64(v)
}

func formatInt64(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [24]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// Keep json import used if needed later; remove if unused.
var _ = json.Marshal
