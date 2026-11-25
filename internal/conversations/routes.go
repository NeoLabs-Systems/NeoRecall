package conversations

import (
	"log/slog"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	reqAuth := rt.Auth.RequireAuth
	read := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireScope("recordings:read", h))
	}
	write := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireScope("recordings:write", h))
	}

	mux.Handle("GET /api/v1/conversations", read(rt.handleList))
	mux.Handle("GET /api/v1/conversations/timeline", read(rt.handleTimeline))
	mux.Handle("GET /api/v1/conversations/pending", read(rt.handlePending))
	mux.Handle("GET /api/v1/conversations/{id}/segments", read(rt.handleSegments))
	mux.Handle("GET /api/v1/conversations/{id}", read(rt.handleGet))
	mux.Handle("DELETE /api/v1/conversations/{id}", write(rt.handleDelete))
	mux.Handle("POST /api/v1/conversations/bulk-delete", write(rt.handleBulk))
	mux.Handle("POST /api/v1/conversations/bulk", write(rt.handleBulk))
	mux.Handle("POST /api/v1/conversations/{id}/reprocess", write(rt.handleReprocess))
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	items, err := rt.Svc.List(r.Context(), a.UserID, ListFilter{
		Limit:   q.Get("limit"),
		State:   q.Get("state"),
		From:    q.Get("from"),
		To:      q.Get("to"),
		Speaker: q.Get("speaker"),
	})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleTimeline(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	res, err := Timeline(r.Context(), rt.Svc.DB.R, a.UserID, q.Get("limit"), q.Get("before"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handlePending(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	p, err := MustGetPending(r.Context(), rt.Svc.DB.R, a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, p)
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	id := r.PathValue("id")
	if id == PendingID {
		p, err := MustGetPending(r.Context(), rt.Svc.DB.R, a.UserID)
		if err != nil {
			httperr.WriteError(w, r, rt.Log, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, p)
		return
	}
	d, err := rt.Svc.Get(r.Context(), a.UserID, id)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, d)
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.Remove(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (rt *Routes) handleBulk(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Action string   `json:"action"`
		IDs    []string `json:"ids"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Action != "" && body.Action != "delete" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Unsupported bulk action."))
		return
	}
	res, err := rt.Svc.BulkRemove(r.Context(), a.UserID, body.IDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleReprocess(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := rt.Svc.Reprocess(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleSegments(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := TimelineSegments(r.Context(), rt.Svc.DB.R, a.UserID, r.PathValue("id"), 1500)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
