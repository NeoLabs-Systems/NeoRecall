package conversations

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
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

// TimelineSegments returns the bounded transcript for a single owned moment.
func TimelineSegments(ctx context.Context, q Queryer, userID, id string, limit int) (map[string]any, error) {
	if id != PendingID {
		var n int
		if err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE user_id=? AND id=?`, userID, id).Scan(&n); err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Conversation not found.")
		}
	}
	where := "ts.conversation_id=?"
	args := []any{userID, id}
	if id == PendingID {
		where = "ts.conversation_id IS NULL"
		args = []any{userID}
	}
	var count int
	if err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM transcript_segments ts WHERE ts.user_id=? AND `+where, args...).Scan(&count); err != nil {
		return nil, err
	}
	queryArgs := append(append([]any{}, args...), limit)
	rows, err := q.QueryContext(ctx, `SELECT ts.id, ts.public_id, ts.user_id, ts.chunk_id, ts.conversation_id,
 ts.speaker_cluster_id, ts.source_component, ts.started_at, ts.ended_at, ts.chunk_start_ms,
 ts.chunk_end_ms, ts.text, ts.language, ts.asr_confidence, ts.speaker_confidence,
 ts.overlapping_speech, ts.created_at, ac.session_id,
 (SELECT v.display_name FROM speaker_turns st JOIN voiceprints v ON v.id=st.voiceprint_id WHERE st.chunk_id=ts.chunk_id AND st.cluster_id=ts.speaker_cluster_id AND st.start_ms<=ts.chunk_start_ms AND st.end_ms>=ts.chunk_end_ms LIMIT 1),
 (SELECT cs.local_label FROM conversation_speakers cs WHERE cs.conversation_id=ts.conversation_id AND cs.cluster_id=ts.speaker_cluster_id LIMIT 1)
 FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
 WHERE ts.user_id=? AND `+where+` ORDER BY ts.started_at,ts.id LIMIT ?`, queryArgs...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	segments := []SegmentRow{}
	for rows.Next() {
		r, err := scanSegment(rows, true, true)
		if err != nil {
			return nil, err
		}
		segments = append(segments, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return map[string]any{"segments": segments, "segmentCount": count, "truncated": count > len(segments)}, nil
}

func Timeline(ctx context.Context, q Queryer, userID, limitRaw, before string) (map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 50, 8)
	var cursor struct {
		StartedAt string `json:"startedAt"`
		ID        string `json:"id"`
	}
	if raw, err := base64.RawURLEncoding.DecodeString(before); err == nil {
		_ = json.Unmarshal(raw, &cursor)
	}
	cond := "user_id=?"
	args := []any{userID}
	if cursor.StartedAt != "" && cursor.ID != "" {
		cond += " AND (started_at<? OR (started_at=? AND id<?))"
		args = append(args, cursor.StartedAt, cursor.StartedAt, cursor.ID)
	} else {
		cursor.StartedAt = ""
	}
	args = append(args, lim+1)
	rows, err := q.QueryContext(ctx, `SELECT `+convSelectCols+` FROM conversations WHERE `+cond+` ORDER BY started_at DESC,id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	items := []ConversationRow{}
	for rows.Next() {
		c, e := scanConversation(rows, false)
		if e != nil {
			rows.Close()
			return nil, e
		}
		items = append(items, c)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	var next any
	if len(items) > lim {
		items = items[:lim]
		last := items[len(items)-1]
		raw, _ := json.Marshal(map[string]string{"startedAt": last.StartedAt, "id": last.ID})
		next = base64.RawURLEncoding.EncodeToString(raw)
	}
	moments := []map[string]any{}
	addMoment := func(id string, m map[string]any) error {
		details, e := TimelineSegments(ctx, q, userID, id, 3)
		if e != nil {
			return e
		}
		m["segments"] = details["segments"]
		m["segmentCount"] = details["segmentCount"]
		where := "t.conversation_id=?"
		a := []any{userID, id}
		if id == PendingID {
			where = "t.conversation_id IS NULL"
			a = []any{userID}
		}
		keys, e := q.QueryContext(ctx, `SELECT DISTINCT c.session_id, COALESCE(json_extract(src.metadata_json, '$.importId'), CASE WHEN src.client_uuid LIKE 'import-source-%' THEN substr(src.client_uuid,15) END) FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id JOIN recording_sources src ON src.id=c.source_id WHERE t.user_id=? AND `+where, a...)
		if e != nil {
			return e
		}
		sessions := []string{}
		imports := []string{}
		seenS := map[string]bool{}
		seenI := map[string]bool{}
		for keys.Next() {
			var session, imp sql.NullString
			if e = keys.Scan(&session, &imp); e != nil {
				keys.Close()
				return e
			}
			if session.Valid && !seenS[session.String] {
				sessions = append(sessions, session.String)
				seenS[session.String] = true
			}
			if imp.Valid && !seenI[imp.String] {
				imports = append(imports, imp.String)
				seenI[imp.String] = true
			}
		}
		e = keys.Err()
		keys.Close()
		if e != nil {
			return e
		}
		m["sessionIds"] = sessions
		m["importIds"] = imports
		moments = append(moments, m)
		return nil
	}
	if cursor.StartedAt == "" {
		p, e := GetPending(ctx, q, userID, false)
		if e != nil {
			return nil, e
		}
		if p != nil {
			if e = addMoment(PendingID, map[string]any{"id": PendingID, "kind": "pending", "startedAt": p.StartedAt, "endedAt": p.EndedAt, "state": "pending", "insightState": nil, "titleEn": nil, "summaryEn": nil, "topics": []string{}, "memoryWorthy": nil, "refinedAt": nil, "quarantined": false}); e != nil {
				return nil, e
			}
		}
	}
	for _, c := range items {
		if err = addMoment(c.ID, map[string]any{"id": c.ID, "kind": "conversation", "startedAt": c.StartedAt, "endedAt": c.EndedAt, "state": c.State, "insightState": c.InsightState, "titleEn": c.TitleEn, "summaryEn": c.SummaryEn, "topics": c.Topics, "memoryWorthy": c.MemoryWorthy, "refinedAt": c.RefinedAt, "quarantined": c.QuarantinedAt != nil}); err != nil {
			return nil, err
		}
	}
	return map[string]any{"moments": moments, "nextCursor": next}, nil
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
