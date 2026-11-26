// Package sources serves the stored server-side sources. Discord voice capture
// was removed deliberately, so nothing here runs one; what remains lets the
// apps list, rename, switch off and delete what accounts already had, including
// the bot token stored with it.
package sources

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

const redacted = "••••••••"

var secretKeys = []string{"token", "accessToken", "refreshToken", "password", "apiKey"}

type Source struct {
	ID                string         `json:"id"`
	UserID            string         `json:"user_id"`
	Type              string         `json:"type"`
	Name              string         `json:"name"`
	Enabled           bool           `json:"enabled"`
	Config            map[string]any `json:"config"`
	ConfiguredSecrets []string       `json:"configuredSecrets"`
	CreatedAt         string         `json:"created_at"`
	UpdatedAt         string         `json:"updated_at"`
}

type Routes struct {
	DB   *dbx.DB
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	route := func(pattern string, h http.HandlerFunc) { mux.Handle(pattern, rt.Auth.RequireAuth(h)) }
	route("GET /api/v1/sources/types", func(w http.ResponseWriter, _ *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"types": []any{}})
	})
	route("GET /api/v1/sources", rt.handleList)
	route("POST /api/v1/sources", func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusGone, "SOURCE_TYPE_REMOVED", "This server no longer offers Discord or other server-side sources."))
	})
	route("GET /api/v1/sources/{id}", rt.handleGet)
	route("PATCH /api/v1/sources/{id}", rt.handlePatch)
	route("DELETE /api/v1/sources/{id}", rt.handleDelete)
}

// query reads the caller's sources, secrets included; redact before replying.
func (rt *Routes) query(ctx context.Context, clause string, args ...any) ([]Source, error) {
	rows, err := rt.DB.R.QueryContext(ctx, `SELECT id, user_id, type, name, enabled, config_json, created_at, updated_at
		FROM sources WHERE `+clause, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Source{}
	for rows.Next() {
		var s Source
		var config string
		if err := rows.Scan(&s.ID, &s.UserID, &s.Type, &s.Name, &s.Enabled, &config, &s.CreatedAt, &s.UpdatedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(config), &s.Config); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func redact(s Source) Source {
	s.ConfiguredSecrets = []string{}
	for _, key := range secretKeys {
		if _, ok := s.Config[key]; ok {
			s.Config[key] = redacted
			s.ConfiguredSecrets = append(s.ConfiguredSecrets, key)
		}
	}
	return s
}

func (rt *Routes) one(r *http.Request) (Source, error) {
	found, err := rt.query(r.Context(), `id=? AND user_id=?`, r.PathValue("id"), auth.FromContext(r.Context()).UserID)
	if err != nil {
		return Source{}, err
	}
	if len(found) == 0 {
		return Source{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Source not found.")
	}
	return found[0], nil
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	found, err := rt.query(r.Context(), `user_id=? ORDER BY created_at DESC`, auth.FromContext(r.Context()).UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	for i := range found {
		found[i] = redact(found[i])
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sources": found})
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	s, err := rt.one(r)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, redact(s))
}

func (rt *Routes) handlePatch(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name    *string        `json:"name"`
		Config  map[string]any `json:"config"`
		Enabled *bool          `json:"enabled"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	s, err := rt.one(r)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Name != nil {
		if n := len([]rune(*body.Name)); n < 1 || n > 100 {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "name must be 1 to 100 characters."))
			return
		}
		s.Name = *body.Name
	}
	if body.Enabled != nil {
		s.Enabled = *body.Enabled
	}
	if s.Config == nil {
		s.Config = map[string]any{}
	}
	// A client only ever saw placeholders, so sending one back keeps the secret.
	for key, value := range body.Config {
		if value != redacted {
			s.Config[key] = value
		}
	}
	config, err := json.Marshal(s.Config)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	s.UpdatedAt = timeutil.NowISO()
	if _, err := rt.DB.W.ExecContext(r.Context(), `UPDATE sources SET name=?, config_json=?, enabled=?, updated_at=? WHERE id=? AND user_id=?`,
		s.Name, string(config), s.Enabled, s.UpdatedAt, s.ID, s.UserID); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, redact(s))
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	res, err := rt.DB.W.ExecContext(r.Context(), `DELETE FROM sources WHERE id=? AND user_id=?`, r.PathValue("id"), auth.FromContext(r.Context()).UserID)
	if err == nil {
		var n int64
		if n, err = res.RowsAffected(); err == nil && n == 0 {
			err = sql.ErrNoRows
		}
	}
	if errors.Is(err, sql.ErrNoRows) {
		err = httperr.New(http.StatusNotFound, "NOT_FOUND", "Source not found.")
	}
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
