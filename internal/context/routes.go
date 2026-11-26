package context

import (
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/google/uuid"
)

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	route := func(pattern, scope string, h http.HandlerFunc) {
		mux.Handle(pattern, rt.Auth.RequireAuth(rt.Auth.RequireScope(scope, h)))
	}
	// The same item operations hang off a recording session and off a memory.
	for _, target := range []struct {
		base, read, write string
		list, create      http.HandlerFunc
	}{
		{"/api/v1/ingest/sessions/{sessionId}/context", "recordings:read", "ingest:write", rt.handleSessionList, rt.handleSessionCreate},
		{"/api/v1/memories/{memoryId}/context", "memories:read", "memories:write", rt.handleMemoryList, rt.handleMemoryCreate},
	} {
		route("GET "+target.base, target.read, target.list)
		route("PUT "+target.base+"/{itemId}", target.write, target.create)
		route("PATCH "+target.base+"/{itemId}", target.write, rt.handleUpdate)
		route("DELETE "+target.base+"/{itemId}", target.write, rt.handleDelete)
		route("POST "+target.base+"/{itemId}/retry", target.write, rt.handleRetry)
		route("GET "+target.base+"/{itemId}/original", target.read, rt.handleOriginal)
	}
	route("POST /api/v1/memories/{memoryId}/context/rewrite", "memories:write", rt.handleMemoryRewrite)
}

func targetOf(r *http.Request) Target {
	return Target{SessionID: r.PathValue("sessionId"), MemoryPublicID: r.PathValue("memoryId")}
}

func (rt *Routes) handleSessionList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	items, err := rt.Svc.ListForSession(r.Context(), a.UserID, r.PathValue("sessionId"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleMemoryList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	items, err := rt.Svc.ListForMemory(r.Context(), a.UserID, r.PathValue("memoryId"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) parseCreateInput(w http.ResponseWriter, r *http.Request) (CreateInput, error) {
	id := r.PathValue("itemId")
	if _, err := uuid.Parse(id); err != nil || len(id) != 36 {
		return CreateInput{}, httperr.New(http.StatusBadRequest, "INVALID_CONTEXT_ID", "Context id must be a UUID.")
	}
	maxBytes := rt.Svc.cfg().ContextMaxFileBytes + 64*1024
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	ct := strings.ToLower(r.Header.Get("Content-Type"))
	if strings.HasPrefix(ct, "multipart/form-data") {
		if err := r.ParseMultipartForm(8 << 20); err != nil {
			return CreateInput{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Malformed multipart context upload.")
		}
		in := CreateInput{
			ID:       id,
			Kind:     strings.TrimSpace(r.FormValue("kind")),
			NoteText: r.FormValue("noteText"),
		}
		if v := strings.TrimSpace(r.FormValue("capturedAt")); v != "" {
			in.CapturedAt = &v
		}
		if v := strings.TrimSpace(r.FormValue("capturedOffsetMs")); v != "" {
			if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
				in.CapturedOffsetMs = &ms
			}
		}
		f, hdr, err := r.FormFile("file")
		if err == nil {
			defer f.Close()
			data, rerr := io.ReadAll(io.LimitReader(f, maxBytes+1))
			if rerr != nil {
				return CreateInput{}, httperr.New(http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", "Attached file exceeds the maximum allowed size.")
			}
			in.FileBytes = data
			if hdr != nil {
				in.FileName = hdr.Filename
				in.ContentType = hdr.Header.Get("Content-Type")
			}
			if declared := r.FormValue("contentType"); declared != "" && (in.ContentType == "" || in.ContentType == "application/octet-stream") {
				in.ContentType = declared
			}
		}
		return in, nil
	}
	var body struct {
		Kind             string  `json:"kind"`
		NoteText         string  `json:"noteText"`
		CapturedOffsetMs *int64  `json:"capturedOffsetMs"`
		CapturedAt       *string `json:"capturedAt"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		return CreateInput{}, err
	}
	return CreateInput{
		ID:               id,
		Kind:             body.Kind,
		NoteText:         body.NoteText,
		CapturedOffsetMs: body.CapturedOffsetMs,
		CapturedAt:       body.CapturedAt,
	}, nil
}

func (rt *Routes) handleSessionCreate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	in, err := rt.parseCreateInput(w, r)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	item, err := rt.Svc.CreateForSession(r.Context(), a.UserID, r.PathValue("sessionId"), in)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"item": item})
}

func (rt *Routes) handleMemoryCreate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	in, err := rt.parseCreateInput(w, r)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	item, queued, err := rt.Svc.CreateForMemory(r.Context(), a.UserID, r.PathValue("memoryId"), in)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"item": item, "rewriteQueued": queued})
}

func (rt *Routes) handleUpdate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		NoteText string `json:"noteText"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	item, err := rt.Svc.UpdateNote(r.Context(), a.UserID, r.PathValue("itemId"), targetOf(r), body.NoteText)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"item": item})
}

func (rt *Routes) handleRetry(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	item, err := rt.Svc.Retry(r.Context(), a.UserID, r.PathValue("itemId"), targetOf(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]any{"item": item})
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.DeleteItem(r.Context(), a.UserID, r.PathValue("itemId"), targetOf(r)); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleOriginal(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	it, plain, err := rt.Svc.ReadOriginal(r.Context(), a.UserID, r.PathValue("itemId"), targetOf(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	ct := "application/octet-stream"
	if it.ContentType != nil && *it.ContentType != "" {
		ct = *it.ContentType
	}
	name := "attachment"
	if it.OriginalName != nil && *it.OriginalName != "" {
		name = *it.OriginalName
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(name))
	w.Header().Set("Content-Length", strconv.Itoa(len(plain)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(plain)
}

func (rt *Routes) handleMemoryRewrite(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if rt.Svc.OnMemoryRewriteRequested == nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusServiceUnavailable, "AI_NOT_CONFIGURED", "Memory rewrite is not configured."))
		return
	}
	memID, _, err := rt.Svc.verifyMemory(r.Context(), a.UserID, r.PathValue("memoryId"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	pubID, err := rt.Svc.OnMemoryRewriteRequested(r.Context(), a.UserID, memID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"rewritten": true, "memoryId": pubID})
}
