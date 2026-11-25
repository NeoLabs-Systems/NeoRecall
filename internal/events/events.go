package events

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type OutboxEvent struct {
	ID           int64
	EventType    string
	ResourceType string
	ResourceID   string
	PayloadJSON  string
}

type Service struct {
	DB  *dbx.DB
	Cfg func() config.Config
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func EmitExec(ctx context.Context, ex interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}, userID, eventType, resourceType, resourceID string, payload any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	exp := timeutil.FormatISO(time.Now().Add(24 * time.Hour))
	_, err = ex.ExecContext(ctx, `INSERT INTO event_outbox
		(user_id, event_type, resource_type, resource_id, payload_json, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`, userID, eventType, resourceType, resourceID, string(raw), exp)
	return err
}

func (s *Service) PollAfter(ctx context.Context, userID string, lastID int64, limit int) ([]OutboxEvent, error) {
	pollMax := s.cfg().EventOutboxPollLimit
	if pollMax <= 0 {
		pollMax = 100
	}
	capLimit := limit
	if capLimit <= 0 {
		capLimit = pollMax
	}
	if capLimit > pollMax {
		capLimit = pollMax
	}
	if lastID < 0 {
		lastID = 0
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, event_type, resource_type, resource_id, payload_json
		FROM event_outbox WHERE user_id=? AND id>? AND expires_at>? ORDER BY id LIMIT ?`,
		userID, lastID, timeutil.NowISO(), capLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []OutboxEvent
	for rows.Next() {
		var ev OutboxEvent
		if err := rows.Scan(&ev.ID, &ev.EventType, &ev.ResourceType, &ev.ResourceID, &ev.PayloadJSON); err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	h := rt.Auth.RequireAuth(rt.Auth.RequireScope("recordings:read", http.HandlerFunc(rt.handleSSE)))
	mux.Handle("GET /api/v1/events", h)
	mux.Handle("GET /api/v1/events/", h)
}

func (rt *Routes) handleSSE(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	var lastID int64
	rawID := r.Header.Get("Last-Event-ID")
	if rawID == "" {
		rawID = r.URL.Query().Get("after")
	}
	if n, err := strconv.ParseInt(rawID, 10, 64); err == nil && n >= 0 {
		lastID = n
	}

	flushBatch := func() bool {
		rows, err := rt.Svc.PollAfter(r.Context(), a.UserID, lastID, 0)
		if err != nil {
			return true
		}
		for _, ev := range rows {
			if _, err := fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", ev.ID, ev.EventType, ev.PayloadJSON); err != nil {
				return false
			}
			lastID = ev.ID
		}
		flusher.Flush()
		return true
	}

	if !flushBatch() {
		return
	}
	keepaliveMs := rt.Svc.cfg().EventOutboxKeepaliveMs
	if keepaliveMs <= 0 {
		keepaliveMs = 15_000
	}
	ticker := time.NewTicker(time.Duration(keepaliveMs) * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": keepalive\n\n"); err != nil {
				return
			}
			flusher.Flush()
			if !flushBatch() {
				return
			}
		}
	}
}
