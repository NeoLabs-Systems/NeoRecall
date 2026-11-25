package sources

import (
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
)

// Routes serves clean stub source endpoints after Discord voice support was intentionally removed.
type Routes struct {
	Auth *auth.Authenticator
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	reqAuth := rt.Auth.RequireAuth
	mux.Handle("GET /api/v1/sources/types", reqAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"types": []any{}})
	})))
	mux.Handle("GET /api/v1/sources", reqAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"sources": []any{}})
	})))
}
