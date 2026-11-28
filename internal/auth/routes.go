package auth

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/account"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type Routes struct {
	Svc     *Service
	Auth    *Authenticator
	Log     *slog.Logger
	UsageFn func(ctx context.Context, userID string) (any, error)
	// Exporter builds the account's data export.
	Exporter  *account.Exporter
	UnlinkFn  func(path string) error
	registerL *httperr.Limiter
	loginL    *httperr.Limiter
	webauthnL *httperr.Limiter
	exportL   *httperr.Limiter
	// QR sign-in and password reset.
	qrChallengeL, qrPollL, resetL *httperr.Limiter
}

func NewRoutes(svc *Service, authenticator *Authenticator, log *slog.Logger) *Routes {
	keyIP := func(r *http.Request) string { return httperr.ClientIP(r, svc.cfg().TrustProxy) }
	keyUser := func(r *http.Request) string {
		if a := FromContext(r.Context()); a != nil {
			return a.UserID
		}
		return httperr.ClientIP(r, svc.cfg().TrustProxy)
	}
	return &Routes{
		Svc: svc, Auth: authenticator, Log: log,
		registerL: httperr.NewLimiter(time.Minute, 10, "RATE_LIMITED", keyIP),
		loginL:    httperr.NewLimiter(time.Minute, 10, "RATE_LIMITED", keyIP),
		webauthnL: httperr.NewLimiter(time.Minute, 20, "RATE_LIMITED", keyIP),
		exportL:   httperr.NewLimiter(15*time.Minute, 5, "RATE_LIMITED", keyUser),

		qrChallengeL: httperr.NewLimiter(time.Minute, 20, "RATE_LIMITED", keyIP),
		qrPollL:      httperr.NewLimiter(time.Minute, 120, "RATE_LIMITED", keyIP),
		resetL:       httperr.NewLimiter(15*time.Minute, 10, "RATE_LIMITED", keyIP),
	}
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	reqAuth := rt.Auth.RequireAuth
	reqSess := func(h http.HandlerFunc) http.Handler {
		return reqAuth(rt.Auth.RequireSession(h))
	}

	rt.mountSignIn(mux)
	rt.mountAccount(mux)
	mux.HandleFunc("POST /api/v1/auth/register", rt.handleRegister)
	mux.HandleFunc("POST /api/v1/auth/login", rt.handleLogin)
	mux.HandleFunc("POST /api/v1/auth/webauthn/options", rt.handleWebAuthnOptions)
	mux.HandleFunc("POST /api/v1/auth/webauthn/verify", rt.handleWebAuthnVerify)

	mux.Handle("GET /api/v1/auth/me", reqAuth(http.HandlerFunc(rt.handleMe)))
	mux.Handle("POST /api/v1/auth/logout", reqAuth(http.HandlerFunc(rt.handleLogout)))

	mux.Handle("PUT /api/v1/auth/password", reqSess(rt.handleChangePassword))
	mux.Handle("POST /api/v1/auth/account/erase-content", reqSess(rt.handleEraseContent))
	mux.Handle("GET /api/v1/auth/account/usage", reqSess(rt.handleAccountUsage))
	mux.Handle("POST /api/v1/auth/2fa/setup", reqSess(rt.handle2FASetup))
	mux.Handle("POST /api/v1/auth/2fa/verify", reqSess(rt.handle2FAVerify))
	mux.Handle("DELETE /api/v1/auth/2fa", reqSess(rt.handle2FADelete))

	// /api/v1/api-keys
	mux.Handle("GET /api/v1/api-keys", reqSess(rt.handleListAPIKeys))
	mux.Handle("GET /api/v1/api-keys/", reqSess(rt.handleListAPIKeys))
	mux.Handle("POST /api/v1/api-keys", reqSess(rt.handleCreateAPIKey))
	mux.Handle("POST /api/v1/api-keys/", reqSess(rt.handleCreateAPIKey))
	mux.Handle("DELETE /api/v1/api-keys/self", reqAuth(http.HandlerFunc(rt.handleRevokeSelfAPIKey)))
	mux.Handle("DELETE /api/v1/api-keys/{id}", reqSess(rt.handleRevokeAPIKey))
}

func (rt *Routes) reqCtx(r *http.Request) RequestContext {
	return RequestContext{
		IPAddress: httperr.ClientIP(r, rt.Svc.cfg().TrustProxy),
		UserAgent: r.UserAgent(),
	}
}

func (rt *Routes) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !rt.registerL.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		Username string  `json:"username"`
		Email    *string `json:"email"`
		Password string  `json:"password"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.Password) > 1024 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	if body.Email != nil && !strings.Contains(*body.Email, "@") {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	u, sess, err := rt.Svc.Register(r.Context(), body.Username, body.Email, body.Password, rt.reqCtx(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"user": u, "session": sess})
}

func (rt *Routes) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !rt.loginL.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		Account       string `json:"account"`
		Username      string `json:"username"` // the shared NeoLabs client's name for it
		Password      string `json:"password"`
		TwoFactorCode string `json:"twoFactorCode"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Account == "" {
		body.Account = body.Username
	}
	if strings.TrimSpace(body.Account) == "" || len(body.Account) > 320 || len(body.Password) > 1024 || len(body.TwoFactorCode) > 64 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	u, sess, err := rt.Svc.Login(r.Context(), body.Account, body.Password, body.TwoFactorCode, rt.reqCtx(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"user": u, "session": sess})
}

func (rt *Routes) handleWebAuthnOptions(w http.ResponseWriter, r *http.Request) {
	if !rt.webauthnL.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		Account string `json:"account"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	cid, opts, err := rt.Svc.BeginWebAuthnAuthentication(r.Context(), r, body.Account)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"challengeId": cid, "options": opts})
}

func (rt *Routes) handleWebAuthnVerify(w http.ResponseWriter, r *http.Request) {
	if !rt.webauthnL.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		ChallengeID   string          `json:"challengeId"`
		Response      json.RawMessage `json:"response"`
		TwoFactorCode string          `json:"twoFactorCode"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if strings.TrimSpace(body.ChallengeID) == "" || len(body.ChallengeID) > 64 || len(body.Response) == 0 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	u, sess, err := rt.Svc.CompleteWebAuthnAuthentication(r.Context(), r, body.ChallengeID, body.Response, body.TwoFactorCode, rt.reqCtx(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"user": u, "session": sess})
}

func (rt *Routes) handleMe(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"user": a.User})
}

func (rt *Routes) handleLogout(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	if a.Type == "session" {
		_ = rt.Svc.Logout(r.Context(), a.SessionID)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleChangePassword(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.NewPassword) > 1024 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The password is too long."))
		return
	}
	if err := rt.Svc.ChangePassword(r.Context(), a.UserID, body.CurrentPassword, body.NewPassword); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleEraseContent(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		Password      string `json:"password"`
		TwoFactorCode string `json:"twoFactorCode"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.EraseContent(r.Context(), a.UserID, body.Password, body.TwoFactorCode, rt.UnlinkFn)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleAccountUsage(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	if rt.UsageFn == nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusInternalServerError, "NOT_CONFIGURED", "Usage service unavailable."))
		return
	}
	snap, err := rt.UsageFn(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, snap)
}

func (rt *Routes) handle2FASetup(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.BeginTwoFactor(r.Context(), a.UserID, a.User.Username, body.Password, body.Code)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handle2FAVerify(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		Code string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.Code) < 6 || len(body.Code) > 64 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	codes, err := rt.Svc.ActivateTwoFactor(r.Context(), a.UserID, body.Code)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"recoveryCodes": codes})
}

func (rt *Routes) handle2FADelete(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.Code == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	if err := rt.Svc.DisableTwoFactor(r.Context(), a.UserID, body.Password, body.Code); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	keys, err := rt.Svc.ListAPIKeys(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"apiKeys": keys})
}

func (rt *Routes) handleCreateAPIKey(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	var body struct {
		Name      string   `json:"name"`
		Scopes    []string `json:"scopes"`
		ExpiresAt *string  `json:"expiresAt"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if strings.TrimSpace(body.Name) == "" || len(body.Name) > 100 || len(body.Scopes) == 0 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	if body.ExpiresAt != nil {
		if _, err := timeutil.ParseISO(*body.ExpiresAt); err != nil {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "expiresAt must be an ISO-8601 datetime."))
			return
		}
	}
	created, err := rt.Svc.CreateAPIKey(r.Context(), a.UserID, body.Name, body.Scopes, body.ExpiresAt)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, created)
}

func (rt *Routes) handleRevokeSelfAPIKey(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	if a.Type != "api_key" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "NOT_AN_API_KEY", "This operation requires an API key, not a session."))
		return
	}
	if err := rt.Svc.RevokeAPIKey(r.Context(), a.UserID, a.APIKeyID); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleRevokeAPIKey(w http.ResponseWriter, r *http.Request) {
	a := FromContext(r.Context())
	if err := rt.Svc.RevokeAPIKey(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
