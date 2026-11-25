package memories

import (
	"log/slog"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type Routes struct {
	Svc            *Service
	Consolidations *ConsolidationService
	Auth           *auth.Authenticator
	Log            *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	reqAuth := rt.Auth.RequireAuth
	read := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireScope("memories:read", h))
	}
	write := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireScope("memories:write", h))
	}

	// Consolidations (/api/v1/memories/consolidations*) registered before /memories/{id}
	mux.Handle("GET /api/v1/memories/consolidations", read(rt.handleConsolidationList))
	mux.Handle("POST /api/v1/memories/consolidations/run", write(rt.handleConsolidationRun))

	mux.Handle("GET /api/v1/memories", read(rt.handleList))
	mux.Handle("GET /api/v1/memories/{id}", read(rt.handleGet))
	mux.Handle("PATCH /api/v1/memories/{id}", write(rt.handlePatch))
	mux.Handle("DELETE /api/v1/memories/{id}", write(rt.handleDelete))
	mux.Handle("POST /api/v1/memories/bulk", write(rt.handleBulk))
	mux.Handle("POST /api/v1/memories/merge", write(rt.handleMerge))

	mux.Handle("GET /api/v1/mini-memories", read(rt.handleListMini))
	mux.Handle("GET /api/v1/mini-memories/{id}", read(rt.handleGetMini))
	mux.Handle("DELETE /api/v1/mini-memories/{id}", write(rt.handleDeleteMini))
	mux.Handle("PATCH /api/v1/mini-memories/{id}", write(rt.handlePatchMini))

	mux.Handle("GET /api/v1/daily-summaries", read(rt.handleListDaily))
	mux.Handle("GET /api/v1/daily-summaries/{date}", read(rt.handleGetDaily))
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	items, err := rt.Svc.List(r.Context(), a.UserID, ListFilter{
		Limit:    q.Get("limit"),
		Type:     q.Get("type"),
		From:     q.Get("from"),
		To:       q.Get("to"),
		Pinned:   q.Get("pinned"),
		Archived: q.Get("archived"),
		Topic:    q.Get("topic"),
	})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	m, err := rt.Svc.Get(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, m)
}

func (rt *Routes) handlePatch(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body MemoryPatch
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	m, err := rt.Svc.Update(r.Context(), a.UserID, r.PathValue("id"), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, m)
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if _, err := rt.Svc.BulkAction(r.Context(), a.UserID, "delete", []string{r.PathValue("id")}); err != nil {
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
	res, err := rt.Svc.BulkAction(r.Context(), a.UserID, body.Action, body.IDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleMerge(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	mem, absorbed, err := rt.Svc.Merge(r.Context(), a.UserID, body.IDs, false)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"memory": mem, "absorbedIds": absorbed})
}

func (rt *Routes) handleListMini(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := r.URL.Query()
	items, err := rt.Svc.ListMini(r.Context(), a.UserID, q.Get("kind"), q.Get("status"), q.Get("limit"), q.Get("memoryId"), q.Get("entity"), q.Get("q"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handlePatchMini(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body MiniPatch
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	_, err := rt.Svc.UpdateMini(r.Context(), a.UserID, r.PathValue("id"), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	mm, err := rt.Svc.MiniDetail(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, mm)
}

func (rt *Routes) handleListDaily(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	items, err := ListDailySummaries(r.Context(), rt.Svc.DB, a.UserID, r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleGetDaily(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	ds, err := GetDailySummary(r.Context(), rt.Svc.DB, a.UserID, r.PathValue("date"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, ds)
}

func (rt *Routes) handleConsolidationList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	items, err := rt.Consolidations.ListRuns(r.Context(), a.UserID, 25)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleConsolidationRun(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	queued, runID, err := rt.Consolidations.Request(r.Context(), a.UserID, true)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	var rid any
	if runID != "" {
		rid = runID
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]any{"queued": queued, "runId": rid})
}

func (rt *Routes) handleGetMini(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	v, err := rt.Svc.MiniDetail(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}
func (rt *Routes) handleDeleteMini(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.RemoveMini(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
