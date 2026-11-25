package auth

import (
	"context"
	"log/slog"
	"net/http"
	"slices"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type authCtxKeyType struct{}

var authCtxKey = authCtxKeyType{}

// AuthContext describes the caller's authenticated identity on a request.
type AuthContext struct {
	Type         string // "session", "api_key", "oauth"
	SessionID    string
	APIKeyID     string
	OAuthTokenID string
	ClientID     string
	ClientName   string
	UserID       string
	Scopes       []string
	User         User
}

// OAuthAuthenticator authenticates nro_ OAuth access tokens.
type OAuthAuthenticator func(ctx context.Context, token string) *AuthContext

// BearerToken extracts the Bearer token from Authorization header.
func BearerToken(r *http.Request) string {
	v := r.Header.Get("Authorization")
	if len(v) > 7 && strings.EqualFold(v[:7], "Bearer ") {
		return strings.TrimSpace(v[7:])
	}
	return ""
}

// ContextWithAuth attaches auth to ctx.
func ContextWithAuth(ctx context.Context, a *AuthContext) context.Context {
	return context.WithValue(ctx, authCtxKey, a)
}

// FromContext returns the authenticated caller from r.Context().
func FromContext(ctx context.Context) *AuthContext {
	a, _ := ctx.Value(authCtxKey).(*AuthContext)
	return a
}

func (a *AuthContext) HasScope(scope string) bool {
	if a == nil {
		return false
	}
	return slices.Contains(a.Scopes, "*") || slices.Contains(a.Scopes, scope)
}

func (a *AuthContext) HasAnyScope(scopes ...string) bool {
	if a == nil {
		return false
	}
	if slices.Contains(a.Scopes, "*") {
		return true
	}
	for _, s := range scopes {
		if slices.Contains(a.Scopes, s) {
			return true
		}
	}
	return false
}

// Authenticator resolves API keys, sessions, and OAuth access tokens in order.
type Authenticator struct {
	Service *Service
	OAuth   OAuthAuthenticator
	Log     *slog.Logger
}

func (au *Authenticator) Resolve(ctx context.Context, token string) *AuthContext {
	if token == "" {
		return nil
	}
	if a := au.Service.AuthenticateAPIKey(ctx, token); a != nil {
		return a
	}
	if a := au.Service.AuthenticateSessionToken(ctx, token); a != nil {
		return a
	}
	if au.OAuth != nil {
		if a := au.OAuth(ctx, token); a != nil {
			return a
		}
	}
	return nil
}

func (au *Authenticator) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := au.Resolve(r.Context(), BearerToken(r))
		if a == nil {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusUnauthorized, "AUTHENTICATION_REQUIRED", "A valid bearer token is required."))
			return
		}
		next.ServeHTTP(w, r.WithContext(ContextWithAuth(r.Context(), a)))
	})
}

func (au *Authenticator) RequireScope(scope string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := FromContext(r.Context())
		if !a.HasScope(scope) {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusForbidden, "INSUFFICIENT_SCOPE", "The "+scope+" scope is required."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (au *Authenticator) RequireAnyScope(scopes []string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := FromContext(r.Context())
		if !a.HasAnyScope(scopes...) {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusForbidden, "INSUFFICIENT_SCOPE", "One of these scopes is required: "+strings.Join(scopes, ", ")+"."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (au *Authenticator) RequireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := FromContext(r.Context())
		if a == nil || a.Type != "session" {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusForbidden, "SESSION_REQUIRED", "An interactive user session is required for this operation."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (au *Authenticator) RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := FromContext(r.Context())
		if a == nil || a.Type != "session" {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusForbidden, "SESSION_REQUIRED", "An interactive user session is required for this operation."))
			return
		}
		if a.User.Role != "admin" {
			httperr.WriteError(w, r, au.Log, httperr.New(http.StatusForbidden, "ADMIN_REQUIRED", "Admin access is required."))
			return
		}
		next.ServeHTTP(w, r)
	})
}
