package transcripts

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

const (
	SpeakerNameColumns = "v.display_name AS voiceprint_name, cs.local_label"
	SpeakerNameJoins   = `LEFT JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id AND st.start_ms<=t.chunk_start_ms AND st.end_ms>=t.chunk_end_ms
		LEFT JOIN voiceprints v ON v.id=st.voiceprint_id
		LEFT JOIN conversation_speakers cs ON cs.conversation_id=t.conversation_id AND cs.cluster_id=t.speaker_cluster_id`
)

type SegmentRow struct {
	ID                int64    `json:"id"`
	PublicID          string   `json:"public_id"`
	UserID            string   `json:"user_id"`
	ChunkID           string   `json:"chunk_id"`
	ConversationID    *string  `json:"conversation_id"`
	SpeakerClusterID  *string  `json:"speaker_cluster_id"`
	SourceComponent   string   `json:"source_component"`
	StartedAt         string   `json:"started_at"`
	EndedAt           string   `json:"ended_at"`
	ChunkStartMs      int      `json:"chunk_start_ms"`
	ChunkEndMs        int      `json:"chunk_end_ms"`
	Text              string   `json:"text"`
	Language          *string  `json:"language"`
	ASRConfidence     *float64 `json:"asr_confidence"`
	SpeakerConfidence *float64 `json:"speaker_confidence"`
	OverlappingSpeech int      `json:"overlapping_speech"`
	CreatedAt         string   `json:"created_at"`
	VoiceprintName    *string  `json:"voiceprint_name"`
	LocalLabel        *string  `json:"local_label"`
}

func ScanSegmentRow(q interface{ Scan(...any) error }) (SegmentRow, error) {
	var r SegmentRow
	var cid, scid, lang, vpName, locLbl sql.NullString
	var asrConf, spkConf sql.NullFloat64
	err := q.Scan(&r.ID, &r.PublicID, &r.UserID, &r.ChunkID, &cid, &scid, &r.SourceComponent,
		&r.StartedAt, &r.EndedAt, &r.ChunkStartMs, &r.ChunkEndMs, &r.Text, &lang,
		&asrConf, &spkConf, &r.OverlappingSpeech, &r.CreatedAt, &vpName, &locLbl)
	if err != nil {
		return SegmentRow{}, err
	}
	if cid.Valid {
		r.ConversationID = &cid.String
	}
	if scid.Valid {
		r.SpeakerClusterID = &scid.String
	}
	if lang.Valid {
		r.Language = &lang.String
	}
	if asrConf.Valid {
		r.ASRConfidence = &asrConf.Float64
	}
	if spkConf.Valid {
		r.SpeakerConfidence = &spkConf.Float64
	}
	if vpName.Valid {
		r.VoiceprintName = &vpName.String
	}
	if locLbl.Valid {
		r.LocalLabel = &locLbl.String
	}
	return r, nil
}

const SegmentSelectCols = `t.id, t.public_id, t.user_id, t.chunk_id, t.conversation_id, t.speaker_cluster_id,
	t.source_component, t.started_at, t.ended_at, t.chunk_start_ms, t.chunk_end_ms, t.text, t.language,
	t.asr_confidence, t.speaker_confidence, t.overlapping_speech, t.created_at, ` + SpeakerNameColumns

type Service struct {
	DB *dbx.DB
}

func PageLimit(raw string, maximum, fallback int) int {
	if raw == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return min(maximum, max(1, v))
}

func (s *Service) List(ctx context.Context, userID, limitRaw, orderRaw, afterRaw, beforeRaw, cursorRaw string) (map[string]any, error) {
	limit := PageLimit(limitRaw, 1000, 100)
	reqOrder := strings.ToLower(strings.TrimSpace(orderRaw))
	asc := reqOrder == "asc" || (reqOrder != "desc" && afterRaw != "")
	curStr := beforeRaw
	if curStr == "" {
		curStr = cursorRaw
	}
	if asc {
		curStr = afterRaw
	}
	var cursor int64
	if curStr != "" {
		if n, err := strconv.ParseInt(curStr, 10, 64); err == nil && n > 0 {
			cursor = n
		}
	}
	bound := "t.id>?"
	dir := "ASC"
	orderName := "asc"
	if !asc {
		dir = "DESC"
		orderName = "desc"
		if cursor > 0 {
			bound = "t.id<?"
		}
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT `+SegmentSelectCols+`
		FROM transcript_segments t
		`+SpeakerNameJoins+`
		WHERE t.user_id=? AND `+bound+` ORDER BY t.id `+dir+` LIMIT ?`,
		userID, cursor, limit+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []SegmentRow{}
	for rows.Next() {
		r, err := ScanSegmentRow(rows)
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
	return map[string]any{"items": items, "nextCursor": nextCursor, "order": orderName}, nil
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	h := rt.Auth.RequireAuth(rt.Auth.RequireScope("recordings:read", http.HandlerFunc(rt.handleList)))
	mux.Handle("GET /api/v1/transcripts", h)
	mux.Handle("GET /api/v1/transcripts/", h)
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	res, err := rt.Svc.List(r.Context(), a.UserID, q.Get("limit"), q.Get("order"), q.Get("after"), q.Get("before"), q.Get("cursor"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
