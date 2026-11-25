package providers

import (
	"log/slog"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	admin := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAdmin(h))
	}
	mux.Handle("GET /api/v1/admin/provider-settings", admin(rt.handleGet))
	mux.Handle("GET /api/v1/admin/provider-settings/", admin(rt.handleGet))
	mux.Handle("POST /api/v1/admin/provider-settings/models", admin(rt.handleDiscoverModels))
	mux.Handle("POST /api/v1/admin/provider-settings/test", admin(rt.handleTestProviders))
	mux.Handle("PUT /api/v1/admin/provider-settings", admin(rt.handleUpdate))
	mux.Handle("PUT /api/v1/admin/provider-settings/", admin(rt.handleUpdate))
	mux.Handle("DELETE /api/v1/admin/provider-settings", admin(rt.handleClear))
	mux.Handle("DELETE /api/v1/admin/provider-settings/", admin(rt.handleClear))
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": rt.Svc.GetAdmin(r.Context())})
}

func (rt *Routes) handleDiscoverModels(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Workload string `json:"workload"`
		Provider string `json:"provider"`
		BaseURL  string `json:"baseUrl"`
		APIKey   string `json:"apiKey"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	out, err := rt.Svc.DiscoverModels(r.Context(), body.Workload, body.Provider, body.BaseURL, body.APIKey)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *Routes) handleTestProviders(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res := rt.Svc.TestProviders(r.Context())
	tOK, _ := res["transcription"].(map[string]any)["ok"].(bool)
	lOK, _ := res["llm"].(map[string]any)["ok"].(bool)
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "provider.test",
		IPAddress: httperr.ClientIP(r, false),
		Metadata:  map[string]any{"transcription": tOK, "llm": lOK},
	})
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleUpdate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body map[string]WorkloadUpdate
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	out, err := rt.Svc.Update(r.Context(), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	meta := map[string]any{}
	for wl, v := range body {
		meta[wl] = map[string]any{
			"provider":       v.Provider,
			"model":          v.Model,
			"baseUrl":        v.BaseURL,
			"language":       v.Language,
			"responseFormat": v.ResponseFormat,
			"apiKeyChanged":  v.APIKey != "" || v.ClearAPIKey,
		}
	}
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "provider_settings_updated",
		IPAddress: httperr.ClientIP(r, false), Metadata: meta,
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": out})
}

func (rt *Routes) handleClear(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	out, err := rt.Svc.ClearOverrides(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "provider_settings_reset",
		IPAddress: httperr.ClientIP(r, false),
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": out})
}
