package context

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

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

	// Session-scoped context endpoints (/api/v1/ingest/sessions/:sessionId/context)
	sessRead := reqAuth(rt.Auth.RequireScope("recordings:read", http.HandlerFunc(rt.handleSessionList)))
	sessWrite := reqAuth(rt.Auth.RequireScope("ingest:write", http.HandlerFunc(rt.handleSessionCreate)))
	sessDel := reqAuth(rt.Auth.RequireScope("ingest:write", http.HandlerFunc(rt.handleDelete)))
	sessDL := reqAuth(rt.Auth.RequireScope("recordings:read", http.HandlerFunc(rt.handleDownload)))

	mux.Handle("GET /api/v1/ingest/sessions/{sessionId}/context", sessRead)
	mux.Handle("POST /api/v1/ingest/sessions/{sessionId}/context", sessWrite)
	mux.Handle("DELETE /api/v1/ingest/sessions/{sessionId}/context/{itemId}", sessDel)
	mux.Handle("GET /api/v1/ingest/sessions/{sessionId}/context/{itemId}/download", sessDL)

	// Memory-scoped context endpoints (/api/v1/memories/:memoryId/context)
	memRead := reqAuth(rt.Auth.RequireScope("memories:read", http.HandlerFunc(rt.handleMemoryList)))
	memWrite := reqAuth(rt.Auth.RequireScope("memories:write", http.HandlerFunc(rt.handleMemoryCreate)))
	memDel := reqAuth(rt.Auth.RequireScope("memories:write", http.HandlerFunc(rt.handleDelete)))
	memDL := reqAuth(rt.Auth.RequireScope("memories:read", http.HandlerFunc(rt.handleDownload)))
	memRewrite := reqAuth(rt.Auth.RequireScope("memories:write", http.HandlerFunc(rt.handleMemoryRewrite)))

	mux.Handle("GET /api/v1/memories/{memoryId}/context", memRead)
	mux.Handle("POST /api/v1/memories/{memoryId}/context", memWrite)
	mux.Handle("DELETE /api/v1/memories/{memoryId}/context/{itemId}", memDel)
	mux.Handle("GET /api/v1/memories/{memoryId}/context/{itemId}/download", memDL)
	mux.Handle("POST /api/v1/memories/{memoryId}/context/rewrite", memRewrite)
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
	maxBytes := rt.Svc.cfg().ContextMaxFileBytes + 64*1024
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	ct := strings.ToLower(r.Header.Get("Content-Type"))
	if strings.HasPrefix(ct, "multipart/form-data") {
		if err := r.ParseMultipartForm(8 << 20); err != nil {
			return CreateInput{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Malformed multipart context upload.")
		}
		in := CreateInput{
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

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.DeleteItem(r.Context(), a.UserID, r.PathValue("itemId")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

func (rt *Routes) handleDownload(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	it, plain, err := rt.Svc.ReadOriginal(r.Context(), a.UserID, r.PathValue("itemId"))
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
		name = strings.ReplaceAll(*it.OriginalName, `"`, "")
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
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
