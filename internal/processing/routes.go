package processing

import (
	"log/slog"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type Routes struct {
	Svc  *Service
	DB   *dbx.DB
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	admin := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAdmin(h))
	}
	mux.Handle("GET /api/v1/admin/processing-settings", admin(rt.handleGet))
	mux.Handle("PUT /api/v1/admin/processing-settings", admin(rt.handlePut))
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": rt.Svc.Get(r.Context())})
}

func (rt *Routes) handlePut(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var patch map[string]any
	if err := httperr.DecodeJSON(r, &patch); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	next, err := rt.Svc.Update(r.Context(), patch)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	_ = audit.Record(r.Context(), rt.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "processing_settings_updated",
		IPAddress: httperr.ClientIP(r, false), Metadata: patch,
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"settings": next})
}
