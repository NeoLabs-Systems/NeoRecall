package cloud

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
		return reqAuth(rt.Auth.RequireScope("settings:read", h))
	}
	write := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireScope("settings:write", h))
	}

	mux.Handle("GET /api/v1/cloud", read(rt.handleGet))
	mux.Handle("PATCH /api/v1/cloud", write(rt.handlePatch))
	mux.Handle("DELETE /api/v1/cloud", write(rt.handleDelete))
	mux.Handle("POST /api/v1/cloud/nextcloud/start", write(rt.handleNCStart))
	mux.Handle("POST /api/v1/cloud/nextcloud/poll", write(rt.handleNCPoll))
	mux.Handle("POST /api/v1/cloud/nextcloud/cancel", write(rt.handleNCCancel))
	mux.Handle("POST /api/v1/cloud/neocloud/start", write(rt.handleNeoStart))
	mux.Handle("POST /api/v1/cloud/neocloud/poll", write(rt.handleNeoPoll))
	mux.Handle("POST /api/v1/cloud/neocloud/cancel", write(rt.handleNeoCancel))
	mux.Handle("POST /api/v1/cloud/backup-now", write(rt.handleBackupNow))
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := rt.Svc.PublicAccount(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if res["connected"] == false {
		if pend := rt.Svc.PublicPending(a.UserID); pend != nil {
			httpx.WriteJSON(w, http.StatusOK, pend)
			return
		}
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handlePatch(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		AudioEnabled      *bool   `json:"audioEnabled"`
		DataBackupEnabled *bool   `json:"dataBackupEnabled"`
		Folder            *string `json:"folder"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.UpdateSettings(r.Context(), a.UserID, body.AudioEnabled, body.DataBackupEnabled, body.Folder)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleDelete(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.Disconnect(r.Context(), a.UserID); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"connected": false, "status": "disconnected"})
}

func (rt *Routes) handleNCStart(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		URL         string `json:"url"`
		InstanceURL string `json:"instanceUrl"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	u := body.URL
	if u == "" {
		u = body.InstanceURL
	}
	res, err := rt.Svc.NextcloudStart(r.Context(), a.UserID, u)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleNCPoll(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := rt.Svc.NextcloudPoll(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if res == nil {
		res, _ = rt.Svc.PublicAccount(r.Context(), a.UserID)
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleNCCancel(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	rt.Svc.NextcloudCancel(a.UserID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"cancelled": true})
}

func (rt *Routes) handleNeoStart(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		URL         string `json:"url"`
		InstanceURL string `json:"instanceUrl"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	u := body.URL
	if u == "" {
		u = body.InstanceURL
	}
	res, err := rt.Svc.NeoCloudStart(r.Context(), a.UserID, u)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleNeoPoll(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, err := rt.Svc.NeoCloudPoll(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if res == nil {
		res, _ = rt.Svc.PublicAccount(r.Context(), a.UserID)
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleNeoCancel(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	rt.Svc.NeoCloudCancel(a.UserID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"cancelled": true})
}

func (rt *Routes) handleBackupNow(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	uploaded, err := rt.Svc.BackupUserData(r.Context(), a.UserID, true)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"uploaded": uploaded})
}
