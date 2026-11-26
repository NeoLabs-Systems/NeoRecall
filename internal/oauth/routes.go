package oauth

import (
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

const (
	oauthCookie      = "neorecall_oauth_session"
	pending2FACookie = "neorecall_oauth_2fa"
)

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger

	companionLim *httperr.Limiter
	registerLim  *httperr.Limiter
	signInLim    *httperr.Limiter
	tokenLim     *httperr.Limiter
}

func NewRoutes(svc *Service, authenticator *auth.Authenticator, log *slog.Logger) *Routes {
	keyIP := func(r *http.Request) string {
		return httperr.ClientIP(r, svc.cfg().TrustProxy)
	}
	return &Routes{
		Svc: svc, Auth: authenticator, Log: log,
		companionLim: httperr.NewLimiter(15*time.Minute, 80, "RATE_LIMITED", keyIP),
		registerLim:  httperr.NewLimiter(15*time.Minute, 80, "RATE_LIMITED", keyIP),
		signInLim:    httperr.NewLimiter(time.Minute, 10, "RATE_LIMITED", keyIP),
		tokenLim:     httperr.NewLimiter(time.Minute, 60, "RATE_LIMITED", keyIP),
	}
}

// CallerBaseURL prefers request headers over configured NEORECALL_PUBLIC_URL.
func CallerBaseURL(r *http.Request, publicURL string) string {
	fProto := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0])
	fHost := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Host"), ",")[0])
	host := fHost
	if host == "" {
		host = strings.TrimSpace(r.Host)
	}
	if host != "" {
		proto := fProto
		if proto == "" {
			if r.TLS != nil {
				proto = "https"
			} else {
				proto = "http"
			}
		}
		return strings.TrimRight(proto+"://"+host, "/")
	}
	if publicURL != "" {
		return strings.TrimRight(publicURL, "/")
	}
	return "http://localhost"
}

func PublicBaseURL(r *http.Request, publicURL string) string {
	if publicURL != "" {
		return strings.TrimRight(publicURL, "/")
	}
	return CallerBaseURL(r, publicURL)
}

func WWWAuthenticate(root string) string {
	return `Bearer realm="NeoRecall", resource_metadata="` + root + `/.well-known/oauth-protected-resource"`
}

func (rt *Routes) isSecureCookie(r *http.Request) bool {
	u, err := url.Parse(PublicBaseURL(r, rt.Svc.cfg().PublicURL))
	return err == nil && u.Scheme == "https"
}

func cookieSeconds(ms int64, fallback int) int {
	if ms <= 0 {
		return fallback
	}
	return max(1, int((ms+999)/1000))
}

func (rt *Routes) setCookie(w http.ResponseWriter, r *http.Request, name, val string, maxAge int) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    url.QueryEscape(val),
		Path:     "/oauth",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   maxAge,
		Secure:   rt.isSecureCookie(r),
	})
}

func (rt *Routes) readCookie(r *http.Request, name string) string {
	c, err := r.Cookie(name)
	if err != nil {
		return ""
	}
	v, err := url.QueryUnescape(c.Value)
	if err != nil {
		return c.Value
	}
	return v
}

func normalizeContinuePath(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "/oauth/authorize"
	}
	u, err := url.Parse(raw)
	if err != nil || u.Path != "/oauth/authorize" {
		return "/oauth/authorize"
	}
	if u.RawQuery != "" {
		return u.Path + "?" + u.RawQuery
	}
	return u.Path
}

func appendRedirect(target string, vals map[string]string) string {
	u, err := url.Parse(target)
	if err != nil {
		return target
	}
	q := u.Query()
	for k, v := range vals {
		if v != "" {
			q.Set(k, v)
		}
	}
	u.RawQuery = q.Encode()
	return u.String()
}

func statusFromErr(err error) int {
	var he *httperr.Error
	if errors.As(err, &he) && he.Status > 0 {
		return he.Status
	}
	return http.StatusBadRequest
}

// Mount registers all OAuth discovery, authorization, token, companion, and integration routes.
func (rt *Routes) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/oauth/companion/neoagent/bootstrap", rt.handleCompanionBootstrap)
	mux.HandleFunc("GET /.well-known/oauth-authorization-server", rt.handleASMetadata)
	mux.HandleFunc("GET /.well-known/oauth-protected-resource", rt.handlePRMetadata)
	mux.HandleFunc("GET /.well-known/oauth-protected-resource/mcp", rt.handlePRMetadata)
	mux.HandleFunc("POST /oauth/register", rt.handleRegister)
	mux.HandleFunc("GET /oauth/sign-in", rt.handleGetSignIn)
	mux.HandleFunc("POST /oauth/sign-in", rt.handlePostSignIn)
	mux.HandleFunc("GET /oauth/authorize", rt.handleGetAuthorize)
	mux.HandleFunc("POST /oauth/authorize", rt.handlePostAuthorize)
	mux.HandleFunc("POST /oauth/token", rt.handleToken)
	mux.HandleFunc("POST /oauth/revoke", rt.handleRevoke)
	mux.HandleFunc("GET /oauth/userinfo", rt.handleUserInfo)

	mux.Handle("GET /api/v1/integrations", rt.Auth.RequireAuth(rt.Auth.RequireSession(http.HandlerFunc(rt.handleListIntegrations))))
	mux.Handle("GET /api/v1/integrations/", rt.Auth.RequireAuth(rt.Auth.RequireSession(http.HandlerFunc(rt.handleListIntegrations))))
	mux.Handle("DELETE /api/v1/integrations/{clientId}", rt.Auth.RequireAuth(rt.Auth.RequireSession(http.HandlerFunc(rt.handleDeleteIntegration))))
}

func (rt *Routes) handleCompanionBootstrap(w http.ResponseWriter, r *http.Request) {
	if !rt.companionLim.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		RedirectURI string `json:"redirectUri"`
		AppName     string `json:"appName"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httpx.WriteJSON(w, statusFromErr(err), map[string]string{"error": err.Error()})
		return
	}
	c, created, err := rt.Svc.CreateCompanionClient(r.Context(), body.RedirectURI, body.AppName)
	if err != nil {
		httpx.WriteJSON(w, statusFromErr(err), map[string]string{"error": err.Error()})
		return
	}
	root := CallerBaseURL(r, rt.Svc.cfg().PublicURL)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"companion":             "neoagent",
		"created":               created,
		"clientId":              c.ID,
		"redirectUri":           c.RedirectURIs[0],
		"scopes":                Scopes,
		"authorizationEndpoint": root + "/oauth/authorize",
		"tokenEndpoint":         root + "/oauth/token",
		"userinfoEndpoint":      root + "/oauth/userinfo",
		"metadataEndpoint":      root + "/.well-known/oauth-authorization-server",
	})
}

func (rt *Routes) handleASMetadata(w http.ResponseWriter, r *http.Request) {
	root := CallerBaseURL(r, rt.Svc.cfg().PublicURL)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"issuer":                                root,
		"authorization_endpoint":                root + "/oauth/authorize",
		"token_endpoint":                        root + "/oauth/token",
		"revocation_endpoint":                   root + "/oauth/revoke",
		"registration_endpoint":                 root + "/oauth/register",
		"userinfo_endpoint":                     root + "/oauth/userinfo",
		"grant_types_supported":                 []string{"authorization_code", "refresh_token"},
		"response_types_supported":              []string{"code"},
		"code_challenge_methods_supported":      []string{"S256"},
		"token_endpoint_auth_methods_supported": []string{"none"},
		"scopes_supported":                      Scopes,
	})
}

func (rt *Routes) handlePRMetadata(w http.ResponseWriter, r *http.Request) {
	root := CallerBaseURL(r, rt.Svc.cfg().PublicURL)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"resource":                 root + "/mcp",
		"authorization_servers":    []string{root},
		"scopes_supported":         Scopes,
		"bearer_methods_supported": []string{"header"},
	})
}

func (rt *Routes) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !rt.registerLim.Allow(w, r, rt.Log) {
		return
	}
	var body RegisterRequest
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_client_metadata", "error_description": err.Error()})
		return
	}
	res, err := rt.Svc.RegisterPublicClient(r.Context(), body)
	if err != nil {
		httpx.WriteJSON(w, statusFromErr(err), map[string]string{"error": "invalid_client_metadata", "error_description": err.Error()})
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, res)
}

func (rt *Routes) handleGetSignIn(w http.ResponseWriter, r *http.Request) {
	cont := normalizeContinuePath(r.URL.Query().Get("continue"))
	if u := rt.Svc.AuthenticateBrowserGrant(r.Context(), rt.readCookie(r, oauthCookie)); u != nil {
		http.Redirect(w, r, cont, http.StatusFound)
		return
	}
	rt.setCookie(w, r, pending2FACookie, "", -1)
	renderPage(w, http.StatusOK, renderSignIn(cont, "", "", false), "")
}

func (rt *Routes) handlePostSignIn(w http.ResponseWriter, r *http.Request) {
	if !rt.signInLim.Allow(w, r, rt.Log) {
		return
	}
	_ = r.ParseForm()
	cont := normalizeContinuePath(r.FormValue("continue"))
	rc := auth.RequestContext{
		IPAddress: httperr.ClientIP(r, rt.Svc.cfg().TrustProxy),
		UserAgent: r.UserAgent(),
	}
	pUserID, pAccount, hasPending := rt.Svc.AuthenticatePendingTwoFactorGrant(r.Context(), rt.readCookie(r, pending2FACookie))
	var u *auth.User
	var err error
	codeVal := r.FormValue("two_factor_code")
	acctVal := r.FormValue("account")
	if hasPending && codeVal != "" {
		u, err = rt.Svc.Auth.CompleteTwoFactor(r.Context(), pUserID, codeVal, rc)
	} else {
		u, err = rt.Svc.Auth.AuthenticateCredentials(r.Context(), acctVal, r.FormValue("password"), codeVal, rc)
	}
	if err != nil {
		var he *httperr.Error
		if errors.As(err, &he) && he.Code == "TWO_FACTOR_REQUIRED" {
			if uid, ok := he.Extra["userId"].(string); ok && uid != "" {
				if grant, gerr := rt.Svc.CreatePendingTwoFactorGrant(uid, acctVal); gerr == nil {
					rt.setCookie(w, r, pending2FACookie, grant, cookieSeconds(rt.Svc.cfg().OAuthPendingTwoFactorTTLMs, 300))
				}
				renderPage(w, http.StatusOK, renderSignIn(cont, "", acctVal, true), "")
				return
			}
		}
		stay2FA := hasPending && errors.As(err, &he) && (he.Code == "INVALID_TWO_FACTOR" || he.Code == "LOGIN_LOCKED")
		displayAcct := acctVal
		if stay2FA && pAccount != "" {
			displayAcct = pAccount
		}
		renderPage(w, statusFromErr(err), renderSignIn(cont, err.Error(), displayAcct, stay2FA), "")
		return
	}
	rt.setCookie(w, r, pending2FACookie, "", -1)
	if grant, gerr := rt.Svc.CreateBrowserGrant(u.ID); gerr == nil {
		rt.setCookie(w, r, oauthCookie, grant, cookieSeconds(rt.Svc.cfg().OAuthBrowserGrantTTLMs, 900))
	}
	http.Redirect(w, r, cont, http.StatusFound)
}

func (rt *Routes) handleGetAuthorize(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	ar, err := rt.Svc.ValidateAuthorizationRequest(r.Context(),
		q.Get("response_type"), q.Get("client_id"), q.Get("redirect_uri"),
		q.Get("state"), q.Get("code_challenge"), q.Get("code_challenge_method"), q.Get("scope"))
	if err != nil {
		renderPage(w, statusFromErr(err), renderError(err.Error()), "")
		return
	}
	if rt.Svc.AuthenticateBrowserGrant(r.Context(), rt.readCookie(r, oauthCookie)) == nil {
		cont := "/oauth/authorize?" + q.Encode()
		http.Redirect(w, r, "/oauth/sign-in?continue="+url.QueryEscape(cont), http.StatusFound)
		return
	}
	renderPage(w, http.StatusOK, renderConsent(ar), ar.RedirectURI)
}

func (rt *Routes) handlePostAuthorize(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	ar, err := rt.Svc.ValidateAuthorizationRequest(r.Context(),
		r.FormValue("response_type"), r.FormValue("client_id"), r.FormValue("redirect_uri"),
		r.FormValue("state"), r.FormValue("code_challenge"), r.FormValue("code_challenge_method"), r.FormValue("scope"))
	if err != nil {
		renderPage(w, statusFromErr(err), renderError(err.Error()), "")
		return
	}
	u := rt.Svc.AuthenticateBrowserGrant(r.Context(), rt.readCookie(r, oauthCookie))
	if u == nil {
		cont := "/oauth/authorize?" + r.PostForm.Encode()
		http.Redirect(w, r, "/oauth/sign-in?continue="+url.QueryEscape(cont), http.StatusFound)
		return
	}
	if r.FormValue("decision") != "approve" {
		rt.setCookie(w, r, oauthCookie, "", -1)
		http.Redirect(w, r, appendRedirect(ar.RedirectURI, map[string]string{"error": "access_denied", "state": ar.State}), http.StatusFound)
		return
	}
	code, err := rt.Svc.CreateAuthorizationCode(r.Context(), ar.Client.ID, u.ID, ar.RedirectURI, ar.Scopes, ar.CodeChallenge)
	if err != nil {
		renderPage(w, http.StatusInternalServerError, renderError(err.Error()), "")
		return
	}
	rt.setCookie(w, r, oauthCookie, "", -1)
	http.Redirect(w, r, appendRedirect(ar.RedirectURI, map[string]string{"code": code, "state": ar.State}), http.StatusFound)
}

func readFormOrJSONParam(r *http.Request, jsonMap map[string]string, key string) string {
	if jsonMap != nil {
		return strings.TrimSpace(jsonMap[key])
	}
	return strings.TrimSpace(r.FormValue(key))
}

func (rt *Routes) handleToken(w http.ResponseWriter, r *http.Request) {
	if !rt.tokenLim.Allow(w, r, rt.Log) {
		return
	}
	var jsonMap map[string]string
	if strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		_ = httperr.DecodeJSON(r, &jsonMap)
	} else {
		_ = r.ParseForm()
	}
	clientID := readFormOrJSONParam(r, jsonMap, "client_id")
	grant := readFormOrJSONParam(r, jsonMap, "grant_type")
	var ts TokenSet
	var err error
	switch grant {
	case "authorization_code":
		ts, err = rt.Svc.ExchangeAuthorizationCode(r.Context(), clientID,
			readFormOrJSONParam(r, jsonMap, "code"),
			readFormOrJSONParam(r, jsonMap, "redirect_uri"),
			readFormOrJSONParam(r, jsonMap, "code_verifier"))
	case "refresh_token":
		ts, err = rt.Svc.RefreshTokenSet(r.Context(), clientID, readFormOrJSONParam(r, jsonMap, "refresh_token"))
	default:
		httpx.WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported_grant_type"})
		return
	}
	if err != nil {
		httpx.WriteJSON(w, statusFromErr(err), map[string]string{"error": "invalid_grant", "error_description": err.Error()})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"access_token":  ts.AccessToken,
		"token_type":    "Bearer",
		"expires_in":    ts.ExpiresIn,
		"refresh_token": ts.RefreshToken,
		"scope":         ts.Scope,
	})
}

func (rt *Routes) handleRevoke(w http.ResponseWriter, r *http.Request) {
	var jsonMap map[string]string
	if strings.Contains(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		_ = httperr.DecodeJSON(r, &jsonMap)
	} else {
		_ = r.ParseForm()
	}
	if err := rt.Svc.RevokeToken(r.Context(), readFormOrJSONParam(r, jsonMap, "client_id"), readFormOrJSONParam(r, jsonMap, "token")); err != nil {
		httpx.WriteJSON(w, statusFromErr(err), map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (rt *Routes) handleUserInfo(w http.ResponseWriter, r *http.Request) {
	a := rt.Svc.AuthenticateAccessToken(r.Context(), auth.BearerToken(r))
	if a == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"sub":                a.UserID,
		"preferred_username": a.User.Username,
		"email":              a.User.Email,
		"client_id":          a.ClientID,
		"client_name":        a.ClientName,
	})
}

func (rt *Routes) handleListIntegrations(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	list, err := rt.Svc.ListUserIntegrations(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"integrations": list})
}

func (rt *Routes) handleDeleteIntegration(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.RevokeUserClient(r.Context(), a.UserID, r.PathValue("clientId")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
