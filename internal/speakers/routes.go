package speakers

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

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
	read := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope("speakers:read", h))
	}
	write := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope("speakers:write", h))
	}

	mux.Handle("GET /api/v1/speakers", read(rt.handleList))
	mux.Handle("GET /api/v1/speakers/", read(rt.handleList))
	mux.Handle("POST /api/v1/speakers/reevaluate", write(rt.handleReevaluate))
	mux.Handle("GET /api/v1/speakers/{id}/preview", read(rt.handlePreview))
	mux.Handle("PATCH /api/v1/speakers/{id}", write(rt.handleUpdate))
	mux.Handle("POST /api/v1/speakers/{id}/merge", write(rt.handleMerge))
	mux.Handle("POST /api/v1/speakers/merge", write(rt.handleMergeMany))
	mux.Handle("POST /api/v1/speakers/bulk", write(rt.handleBulk))
	mux.Handle("POST /api/v1/speakers/{id}/assignments", write(rt.handleAssign))
	mux.Handle("DELETE /api/v1/speakers/{id}", write(rt.handleDelete))
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	list, err := rt.Svc.List(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"speakers": list})
}

func (rt *Routes) handleReevaluate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	queued := rt.Svc.RequestConversationResolution(r.Context(), a.UserID)
	res, err := rt.Svc.Reevaluate(r.Context(), a.UserID, true)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"mergedCount":         res.MergedCount,
		"remainingCount":      res.RemainingCount,
		"merges":              res.Merges,
		"queuedConversations": queued,
	})
}

func (rt *Routes) handlePreview(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	preview, err := rt.Svc.GetPreview(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if preview == nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusNotFound, "NOT_FOUND", "Speaker preview not found."))
		return
	}
	w.Header().Set("Content-Type", preview.ContentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(preview.Audio)))
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(preview.Audio)
}

func (rt *Routes) handleUpdate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var raw map[string]json.RawMessage
	if err := httperr.DecodeJSON(r, &raw); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	var hasDN bool
	var dn *string
	if msg, ok := raw["displayName"]; ok {
		hasDN = true
		if string(msg) != "null" {
			var s string
			if err := json.Unmarshal(msg, &s); err != nil || len(s) == 0 || len(s) > 120 {
				httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid displayName."))
				return
			}
			dn = &s
		}
	}
	var me *bool
	if msg, ok := raw["matchingEnabled"]; ok {
		var b bool
		if err := json.Unmarshal(msg, &b); err != nil {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid matchingEnabled."))
			return
		}
		me = &b
	}
	vp, err := rt.Svc.Update(r.Context(), a.UserID, r.PathValue("id"), hasDN, dn, me)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, vp)
}

func (rt *Routes) handleMerge(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		SourceID string `json:"sourceId"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.SourceID == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "sourceId is required."))
		return
	}
	vp, err := rt.Svc.Merge(r.Context(), a.UserID, r.PathValue("id"), body.SourceID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, vp)
}

func (rt *Routes) handleMergeMany(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		TargetID  string   `json:"targetId"`
		SourceIDs []string `json:"sourceIds"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.TargetID == "" || len(body.SourceIDs) == 0 || len(body.SourceIDs) > 20 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "targetId and 1–20 sourceIds are required."))
		return
	}
	for _, s := range body.SourceIDs {
		if s == "" {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid sourceId."))
			return
		}
	}
	vp, err := rt.Svc.MergeMany(r.Context(), a.UserID, body.TargetID, body.SourceIDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, vp)
}

func (rt *Routes) handleBulk(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		IDs    []string `json:"ids"`
		Action string   `json:"action"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Action != "delete" || len(body.IDs) == 0 || len(body.IDs) > 100 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid bulk action."))
		return
	}
	for _, id := range body.IDs {
		if id == "" {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid speaker id."))
			return
		}
	}
	out, err := rt.Svc.BulkRemove(r.Context(), a.UserID, body.IDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *Routes) handleAssign(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		TurnIDs []string `json:"turnIds"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.TurnIDs) == 0 || len(body.TurnIDs) > 1000 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "1–1000 turnIds required."))
		return
	}
	assigned, err := rt.Svc.Assign(r.Context(), a.UserID, r.PathValue("id"), body.TurnIDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"assigned": assigned})
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.Remove(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"success": true})
}
