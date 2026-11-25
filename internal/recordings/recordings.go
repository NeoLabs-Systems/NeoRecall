package recordings

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
)

type SearchSourceRef struct {
	Kind     string
	SourceID string
}

type SessionListItem struct {
	ID                   string  `json:"id"`
	UserID               string  `json:"user_id"`
	DeviceID             string  `json:"device_id"`
	ClientUUID           string  `json:"client_uuid"`
	DeviceStartedAt      string  `json:"device_started_at"`
	CorrectedStartedAt   string  `json:"corrected_started_at"`
	DeviceEndedAt        *string `json:"device_ended_at"`
	CorrectedEndedAt     *string `json:"corrected_ended_at"`
	Timezone             string  `json:"timezone"`
	InitialClockOffsetMs int64   `json:"initial_clock_offset_ms"`
	ConsentAttestedAt    string  `json:"consent_attested_at"`
	Status               string  `json:"status"`
	CreatedAt            string  `json:"created_at"`
	UpdatedAt            string  `json:"updated_at"`
	ChunkCount           int     `json:"chunk_count"`
	SegmentCount         int     `json:"segment_count"`
}

type GapRow struct {
	ID            string `json:"id"`
	SessionID     string `json:"session_id"`
	SourceID      string `json:"source_id"`
	StartOffsetMs int    `json:"start_offset_ms"`
	EndOffsetMs   int    `json:"end_offset_ms"`
	StartSequence *int   `json:"start_sequence"`
	EndSequence   *int   `json:"end_sequence"`
	Reason        string `json:"reason"`
	CreatedAt     string `json:"created_at"`
}

type SourceRow struct {
	ID                    string  `json:"id"`
	SessionID             string  `json:"session_id"`
	ClientUUID            string  `json:"client_uuid"`
	Kind                  string  `json:"kind"`
	ChannelLayout         string  `json:"channel_layout"`
	SampleRate            int     `json:"sample_rate"`
	SampleFormat          string  `json:"sample_format"`
	MetadataJSON          string  `json:"metadata_json"`
	FinalSequence         *int    `json:"final_sequence"`
	ClosedAt              *string `json:"closed_at"`
	ContiguousTerminalSeq *int    `json:"contiguous_terminal_sequence"`
	CreatedAt             string  `json:"created_at"`
}

type SessionDetail struct {
	ID                   string      `json:"id"`
	UserID               string      `json:"user_id"`
	DeviceID             string      `json:"device_id"`
	ClientUUID           string      `json:"client_uuid"`
	DeviceStartedAt      string      `json:"device_started_at"`
	CorrectedStartedAt   string      `json:"corrected_started_at"`
	DeviceEndedAt        *string     `json:"device_ended_at"`
	CorrectedEndedAt     *string     `json:"corrected_ended_at"`
	Timezone             string      `json:"timezone"`
	InitialClockOffsetMs float64     `json:"initial_clock_offset_ms"`
	ConsentAttestedAt    string      `json:"consent_attested_at"`
	Status               string      `json:"status"`
	CreatedAt            string      `json:"created_at"`
	UpdatedAt            string      `json:"updated_at"`
	Sources              []SourceRow `json:"sources"`
	Gaps                 []GapRow    `json:"gaps"`
}

type Service struct {
	DB                  *dbx.DB
	MasterKey           func() ([]byte, error)
	Speakers            *speakers.Service
	RemoveSearchSources func(ctx context.Context, tx *sql.Tx, userID string, refs []SearchSourceRef) error
	Log                 *slog.Logger
}

func encodeCursor(v any) string {
	b, _ := json.Marshal(v)
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeCursor(raw string) map[string]any {
	if raw == "" {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil
	}
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

func (s *Service) List(ctx context.Context, userID, limitRaw, cursorRaw string) (map[string]any, error) {
	limit := transcripts.PageLimit(limitRaw, 100, 50)
	cur := decodeCursor(cursorRaw)
	var startedCursor sql.NullString
	if st, _ := cur["startedAt"].(string); st != "" {
		startedCursor = sql.NullString{String: st, Valid: true}
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT r.id, r.user_id, r.device_id, r.client_uuid, r.device_started_at, r.corrected_started_at,
		r.device_ended_at, r.corrected_ended_at, r.timezone, COALESCE(r.initial_clock_offset_ms,0), r.consent_attested_at, r.status, r.created_at, r.updated_at,
		(SELECT COUNT(*) FROM audio_chunks c WHERE c.session_id=r.id) AS chunk_count,
		(SELECT COUNT(*) FROM transcript_segments t WHERE t.chunk_id IN (SELECT id FROM audio_chunks WHERE session_id=r.id)) AS segment_count
		FROM recording_sessions r WHERE r.user_id=? AND (? IS NULL OR r.corrected_started_at < ?)
		ORDER BY r.corrected_started_at DESC, r.id DESC LIMIT ?`, userID, startedCursor, startedCursor, limit+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []SessionListItem{}
	for rows.Next() {
		var it SessionListItem
		var de, ce sql.NullString
		var off float64
		if err := rows.Scan(&it.ID, &it.UserID, &it.DeviceID, &it.ClientUUID, &it.DeviceStartedAt, &it.CorrectedStartedAt,
			&de, &ce, &it.Timezone, &off, &it.ConsentAttestedAt, &it.Status, &it.CreatedAt, &it.UpdatedAt,
			&it.ChunkCount, &it.SegmentCount); err != nil {
			return nil, err
		}
		it.InitialClockOffsetMs = int64(off)
		if de.Valid {
			it.DeviceEndedAt = &de.String
		}
		if ce.Valid {
			it.CorrectedEndedAt = &ce.String
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	more := len(items) > limit
	if more {
		items = items[:limit]
	}
	var nextCursor *string
	if more && len(items) > 0 {
		enc := encodeCursor(map[string]any{"startedAt": items[len(items)-1].CorrectedStartedAt})
		nextCursor = &enc
	}
	return map[string]any{"items": items, "nextCursor": nextCursor}, nil
}

func (s *Service) Get(ctx context.Context, userID, id string) (SessionDetail, error) {
	var d SessionDetail
	var de, ce sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, user_id, device_id, client_uuid, device_started_at, corrected_started_at,
		device_ended_at, corrected_ended_at, timezone, COALESCE(initial_clock_offset_ms,0), consent_attested_at, status, created_at, updated_at
		FROM recording_sessions WHERE id=? AND user_id=?`, id, userID).
		Scan(&d.ID, &d.UserID, &d.DeviceID, &d.ClientUUID, &d.DeviceStartedAt, &d.CorrectedStartedAt,
			&de, &ce, &d.Timezone, &d.InitialClockOffsetMs, &d.ConsentAttestedAt, &d.Status, &d.CreatedAt, &d.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return SessionDetail{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Recording not found.")
	}
	if err != nil {
		return SessionDetail{}, err
	}
	if de.Valid {
		d.DeviceEndedAt = &de.String
	}
	if ce.Valid {
		d.CorrectedEndedAt = &ce.String
	}

	d.Sources = []SourceRow{}
	sRows, err := s.DB.R.QueryContext(ctx, `SELECT id, session_id, client_uuid, kind, channel_layout, sample_rate, sample_format,
		metadata_json, final_sequence, closed_at, contiguous_terminal_sequence, created_at
		FROM recording_sources WHERE session_id=? ORDER BY created_at`, id)
	if err == nil {
		for sRows.Next() {
			var src SourceRow
			var fs, cts sql.NullInt64
			var ca sql.NullString
			if sRows.Scan(&src.ID, &src.SessionID, &src.ClientUUID, &src.Kind, &src.ChannelLayout, &src.SampleRate,
				&src.SampleFormat, &src.MetadataJSON, &fs, &ca, &cts, &src.CreatedAt) == nil {
				if fs.Valid {
					v := int(fs.Int64)
					src.FinalSequence = &v
				}
				if ca.Valid {
					src.ClosedAt = &ca.String
				}
				if cts.Valid {
					v := int(cts.Int64)
					src.ContiguousTerminalSeq = &v
				}
				d.Sources = append(d.Sources, src)
			}
		}
		sRows.Close()
	}

	d.Gaps = []GapRow{}
	gRows, err := s.DB.R.QueryContext(ctx, `SELECT id, session_id, source_id, start_offset_ms, end_offset_ms,
		start_sequence, end_sequence, reason, created_at FROM recording_gaps WHERE session_id=? ORDER BY start_offset_ms`, id)
	if err == nil {
		for gRows.Next() {
			var g GapRow
			var ss, es sql.NullInt64
			if gRows.Scan(&g.ID, &g.SessionID, &g.SourceID, &g.StartOffsetMs, &g.EndOffsetMs, &ss, &es, &g.Reason, &g.CreatedAt) == nil {
				if ss.Valid {
					v := int(ss.Int64)
					g.StartSequence = &v
				}
				if es.Valid {
					v := int(es.Int64)
					g.EndSequence = &v
				}
				d.Gaps = append(d.Gaps, g)
			}
		}
		gRows.Close()
	}
	return d, nil
}

func (s *Service) Transcript(ctx context.Context, userID, id, limitRaw, cursorRaw string) (map[string]any, error) {
	if _, err := s.Get(ctx, userID, id); err != nil {
		return nil, err
	}
	limit := transcripts.PageLimit(limitRaw, 250, 100)
	var cursor int64
	if cursorRaw != "" {
		if n, err := strconv.ParseInt(cursorRaw, 10, 64); err == nil {
			cursor = n
		}
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+transcripts.SegmentSelectCols+`
		FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
		`+transcripts.SpeakerNameJoins+`
		WHERE c.session_id=? AND t.user_id=? AND t.id>? ORDER BY t.id LIMIT ?`,
		id, userID, cursor, limit+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []transcripts.SegmentRow{}
	for rows.Next() {
		r, err := transcripts.ScanSegmentRow(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	more := len(items) > limit
	if more {
		items = items[:limit]
	}
	var nextCursor *string
	if more && len(items) > 0 {
		s := strconv.FormatInt(items[len(items)-1].ID, 10)
		nextCursor = &s
	}
	return map[string]any{"items": items, "nextCursor": nextCursor}, nil
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

func dateInTimezone(iso, tz string) string {
	t, err := timeutil.ParseISO(iso)
	if err != nil {
		return iso[:min(10, len(iso))]
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	return t.In(loc).Format("2006-01-02")
}

func (s *Service) Remove(ctx context.Context, userID, id string) error {
	sess, err := s.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	key, err := s.MasterKey()
	if err != nil {
		return err
	}

	var tempFiles, ctxFiles []string
	if r, err := s.DB.R.QueryContext(ctx, `SELECT temporary_path FROM audio_chunks WHERE session_id=? AND user_id=? AND temporary_path IS NOT NULL`, id, userID); err == nil {
		for r.Next() {
			var p string
			if r.Scan(&p) == nil {
				tempFiles = append(tempFiles, p)
			}
		}
		r.Close()
	}
	if r, err := s.DB.R.QueryContext(ctx, `SELECT original_path FROM recording_context_items WHERE session_id=? AND user_id=? AND original_path IS NOT NULL`, id, userID); err == nil {
		for r.Next() {
			var p string
			if r.Scan(&p) == nil {
				ctxFiles = append(ctxFiles, p)
			}
		}
		r.Close()
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// Remove derived segments, conversations, memories, mini-memories, daily summaries.
	var segIDs []string
	convSet := make(map[string]bool)
	if r, err := tx.QueryContext(ctx, `SELECT t.id, t.conversation_id FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?`, id, userID); err == nil {
		for r.Next() {
			var sid string
			var cid sql.NullString
			if r.Scan(&sid, &cid) == nil {
				segIDs = append(segIDs, sid)
				if cid.Valid && cid.String != "" {
					convSet[cid.String] = true
				}
			}
		}
		r.Close()
	}

	var memIDs []any
	if r, err := tx.QueryContext(ctx, `SELECT DISTINCT m.id FROM memories m JOIN memory_sources ms ON ms.memory_id=m.id
		WHERE m.user_id=? AND (
			ms.segment_id IN (SELECT t.id FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?)
			OR ms.conversation_id IN (SELECT DISTINCT t.conversation_id FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=? AND t.conversation_id IS NOT NULL)
		)`, userID, id, userID, id, userID); err == nil {
		for r.Next() {
			var mid string
			if r.Scan(&mid) == nil {
				memIDs = append(memIDs, mid)
			}
		}
		r.Close()
	}

	var miniIDs []string
	if len(memIDs) > 0 {
		args := append([]any{userID}, memIDs...)
		ph := placeholders(len(memIDs))
		if r, err := tx.QueryContext(ctx, `SELECT original_path FROM recording_context_items WHERE user_id=? AND memory_id IN (`+ph+`) AND original_path IS NOT NULL`, args...); err == nil {
			for r.Next() {
				var p string
				if r.Scan(&p) == nil {
					ctxFiles = append(ctxFiles, p)
				}
			}
			r.Close()
		}
		if r, err := tx.QueryContext(ctx, `SELECT id FROM mini_memories WHERE user_id=? AND memory_id IN (`+ph+`)`, args...); err == nil {
			for r.Next() {
				var mmid string
				if r.Scan(&mmid) == nil {
					miniIDs = append(miniIDs, mmid)
				}
			}
			r.Close()
		}
	}

	coverageEnd := ""
	if sess.CorrectedEndedAt != nil {
		coverageEnd = *sess.CorrectedEndedAt
	}
	if coverageEnd == "" {
		var maxEnded sql.NullString
		_ = tx.QueryRowContext(ctx, `SELECT MAX(t.ended_at) FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id WHERE c.session_id=? AND t.user_id=?`, id, userID).Scan(&maxEnded)
		coverageEnd = maxEnded.String
	}
	if coverageEnd == "" {
		coverageEnd = sess.CorrectedStartedAt
	}

	var summaryIDs []string
	if r, err := tx.QueryContext(ctx, `SELECT id, timezone, local_date, coverage_started_at, coverage_ended_at FROM daily_summaries WHERE user_id=?`, userID); err == nil {
		for r.Next() {
			var sumID, tz, ldate string
			var cs, ce sql.NullString
			if r.Scan(&sumID, &tz, &ldate, &cs, &ce) == nil {
				overlapsCov := cs.Valid && ce.Valid && cs.String <= coverageEnd && ce.String >= sess.CorrectedStartedAt
				startDate := dateInTimezone(sess.CorrectedStartedAt, tz)
				endDate := dateInTimezone(coverageEnd, tz)
				if overlapsCov || (ldate >= startDate && ldate <= endDate) {
					summaryIDs = append(summaryIDs, sumID)
				}
			}
		}
		r.Close()
	}

	if s.RemoveSearchSources != nil {
		var refs []SearchSourceRef
		for _, sid := range segIDs {
			refs = append(refs, SearchSourceRef{Kind: "segment", SourceID: sid})
		}
		for _, mid := range memIDs {
			refs = append(refs, SearchSourceRef{Kind: "memory", SourceID: mid.(string)})
		}
		for _, mmid := range miniIDs {
			refs = append(refs, SearchSourceRef{Kind: "mini_memory", SourceID: mmid})
		}
		for _, sumID := range summaryIDs {
			refs = append(refs, SearchSourceRef{Kind: "daily_summary", SourceID: sumID})
		}
		if err := s.RemoveSearchSources(ctx, tx, userID, refs); err != nil {
			return err
		}
	}

	if len(memIDs) > 0 {
		args := append([]any{userID}, memIDs...)
		if _, err := tx.ExecContext(ctx, `DELETE FROM memories WHERE user_id=? AND id IN (`+placeholders(len(memIDs))+`)`, args...); err != nil {
			return err
		}
	}
	for _, sumID := range summaryIDs {
		if _, err := tx.ExecContext(ctx, `DELETE FROM daily_summaries WHERE id=? AND user_id=?`, sumID, userID); err != nil {
			return err
		}
	}
	for cid := range convSet {
		if _, err := tx.ExecContext(ctx, `DELETE FROM conversations WHERE id=? AND user_id=?`, cid, userID); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM entities WHERE user_id=? AND id NOT IN (SELECT entity_id FROM memory_entities)
		AND id NOT IN (SELECT entity_id FROM mini_memory_entities) AND id NOT IN (SELECT entity_id FROM voiceprints WHERE entity_id IS NOT NULL)`, userID); err != nil {
		return err
	}

	if s.Speakers != nil {
		if err := s.Speakers.RebuildAffectedVoiceprints(ctx, tx, key, userID, id); err != nil {
			return err
		}
	}

	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE user_id=? AND status IN ('queued','leased') AND resource_id IN (SELECT id FROM audio_chunks WHERE session_id=?)`, userID, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET status='cancelled', lease_owner=NULL, lease_expires_at=NULL,
		updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE user_id=? AND status IN ('queued','leased') AND resource_type='recording_context'
		AND resource_id IN (SELECT id FROM recording_context_items WHERE session_id=?)`, userID, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM recording_sessions WHERE id=? AND user_id=?`, id, userID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	for _, p := range tempFiles {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) && s.Log != nil {
			s.Log.Error("Recording deleted but temporary audio file remains for sweep", "path", p, "error", err)
		}
	}
	for _, p := range ctxFiles {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) && s.Log != nil {
			s.Log.Error("Recording deleted but attached context file remains for sweep", "path", p, "error", err)
		}
	}
	return nil
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	read := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope("recordings:read", h))
	}
	write := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope("recordings:write", h))
	}

	mux.Handle("GET /api/v1/recordings", read(rt.handleList))
	mux.Handle("GET /api/v1/recordings/", read(rt.handleList))
	mux.Handle("GET /api/v1/recordings/{id}/transcript", read(rt.handleTranscript))
	mux.Handle("GET /api/v1/recordings/{id}", read(rt.handleGet))
	mux.Handle("DELETE /api/v1/recordings/{id}", write(rt.handleDelete))
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	res, err := rt.Svc.List(r.Context(), a.UserID, q.Get("limit"), q.Get("cursor"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleTranscript(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	res, err := rt.Svc.Transcript(r.Context(), a.UserID, r.PathValue("id"), q.Get("limit"), q.Get("cursor"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := rt.Svc.Get(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.Remove(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
