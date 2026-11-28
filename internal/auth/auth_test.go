package auth_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/oauth"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
)

func setupTestStack(t *testing.T, adminUsers ...string) (*http.ServeMux, *dbx.DB, *auth.Service, *oauth.Service) {
	t.Helper()
	ctx := context.Background()
	home := t.TempDir()
	env := func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "NEORECALL_ADMIN_USERS":
			return strings.Join(adminUsers, ",")
		}
		return ""
	}
	cfg, err := config.Load(env, home, home)
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.Paths.Ensure(); err != nil {
		t.Fatal(err)
	}
	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	keyFn := func() ([]byte, error) {
		return crypto.MasterKey(cfg.Paths.SecretKey)
	}
	svc := auth.NewService(db, func() config.Config { return cfg }, keyFn)
	oauthSvc := &oauth.Service{
		DB:        db,
		Auth:      svc,
		Cfg:       func() config.Config { return cfg },
		MasterKey: keyFn,
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	authn := &auth.Authenticator{
		Service: svc,
		OAuth:   oauthSvc.AuthenticateAccessToken,
		Log:     log,
	}
	mux := http.NewServeMux()
	routes := auth.NewRoutes(svc, authn, log)
	routes.Exporter = (&cloud.Service{DB: db, Cfg: func() config.Config { return cfg }}).Exporter()
	routes.UnlinkFn = ingest.UnlinkStrict
	routes.Mount(mux)
	oauth.NewRoutes(oauthSvc, authn, log).Mount(mux)
	return mux, db, svc, oauthSvc
}

func TestAuthAndOAuthPKCEFlow(t *testing.T) {
	mux, _, svc, _ := setupTestStack(t, "reservedadmin")
	srv := httptest.NewServer(mux)
	defer srv.Close()

	// 1. Reserved admin name cannot be registered.
	res, _ := http.Post(srv.URL+"/api/v1/auth/register", "application/json",
		strings.NewReader(`{"username":"reservedadmin","password":"Orchid-Tram-58-Lagoon"}`))
	if res.StatusCode != 409 {
		t.Fatalf("expected 409 for reserved admin username, got %d", res.StatusCode)
	}
	res.Body.Close()

	// 2. First registered user becomes admin.
	res, err := http.Post(srv.URL+"/api/v1/auth/register", "application/json",
		strings.NewReader(`{"username":"alice","email":"Alice@Example.com","password":"Orchid-Tram-58-Lagoon"}`))
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("register failed: status=%v err=%v", res.StatusCode, err)
	}
	var regOut struct {
		User    auth.User         `json:"user"`
		Session auth.SessionToken `json:"session"`
	}
	_ = json.NewDecoder(res.Body).Decode(&regOut)
	res.Body.Close()
	if regOut.User.Role != "admin" || !strings.HasPrefix(regOut.Session.Token, "nrs_") {
		t.Fatalf("unexpected register payload: %+v", regOut)
	}

	// 3. API Key create, authenticate, self-revoke.
	req, _ := http.NewRequest("POST", srv.URL+"/api/v1/api-keys", strings.NewReader(`{"name":"device","scopes":["search:read"]}`))
	req.Header.Set("Authorization", "Bearer "+regOut.Session.Token)
	req.Header.Set("Content-Type", "application/json")
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != 201 {
		t.Fatalf("create api key status %d", res.StatusCode)
	}
	var keyOut auth.CreatedAPIKey
	_ = json.NewDecoder(res.Body).Decode(&keyOut)
	res.Body.Close()
	if !strings.HasPrefix(keyOut.Token, "nrk_") {
		t.Fatalf("unexpected api key prefix: %q", keyOut.Token)
	}

	// Verify API key cannot call session-only route.
	req, _ = http.NewRequest("GET", srv.URL+"/api/v1/integrations", nil)
	req.Header.Set("Authorization", "Bearer "+keyOut.Token)
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != 403 {
		t.Fatalf("expected 403 session required for API key, got %d", res.StatusCode)
	}
	res.Body.Close()

	// 4. Enable 2FA & verify login requires TOTP, accepts recovery code.
	setup, err := svc.BeginTwoFactor(context.Background(), regOut.User.ID, "alice", "", "")
	if err != nil {
		t.Fatal(err)
	}
	code, _ := totp.Code(setup.Secret, time.Now())
	recCodes, err := svc.ActivateTwoFactor(context.Background(), regOut.User.ID, code)
	if err != nil || len(recCodes) != 10 {
		t.Fatalf("ActivateTwoFactor failed: %v %d", err, len(recCodes))
	}

	res, _ = http.Post(srv.URL+"/api/v1/auth/login", "application/json",
		strings.NewReader(`{"account":"alice","password":"Orchid-Tram-58-Lagoon"}`))
	if res.StatusCode != 401 {
		t.Fatalf("expected 401 TWO_FACTOR_REQUIRED, got %d", res.StatusCode)
	}
	res.Body.Close()

	// OAuth PKCE dynamic registration + companion bootstrap + token exchange + refresh rotation.
	res, _ = http.Post(srv.URL+"/api/oauth/companion/neoagent/bootstrap", "application/json",
		strings.NewReader(`{"redirectUri":"http://127.0.0.1:4999/api/integrations/oauth/callback","appName":"NeoAgent"}`))
	if res.StatusCode != 200 {
		t.Fatalf("companion bootstrap status %d", res.StatusCode)
	}
	var boot struct {
		ClientID    string `json:"clientId"`
		RedirectURI string `json:"redirectUri"`
	}
	_ = json.NewDecoder(res.Body).Decode(&boot)
	res.Body.Close()

	// Authenticate browser grant directly via form login with 2FA.
	jarClient := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	form := url.Values{"account": {"alice"}, "password": {"Orchid-Tram-58-Lagoon"}, "two_factor_code": {recCodes[0]}, "continue": {"/oauth/authorize"}}
	res, _ = jarClient.PostForm(srv.URL+"/oauth/sign-in", form)
	if res.StatusCode != 302 {
		b, _ := io.ReadAll(res.Body)
		t.Fatalf("oauth sign-in expected 302, got %d: %s", res.StatusCode, string(b))
	}
	cookies := res.Cookies()
	res.Body.Close()

	verifier := "verifier-secret-string-that-is-at-least-43-bytes-long"
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])

	authReq, _ := http.NewRequest("POST", srv.URL+"/oauth/authorize", strings.NewReader(url.Values{
		"response_type":         {"code"},
		"client_id":             {boot.ClientID},
		"redirect_uri":          {boot.RedirectURI},
		"state":                 {"state-token-at-least-16-chars"},
		"scope":                 {"search:read memories:read"},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"decision":              {"approve"},
	}.Encode()))
	authReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range cookies {
		authReq.AddCookie(c)
	}
	res, _ = jarClient.Do(authReq)
	if res.StatusCode != 302 {
		b, _ := io.ReadAll(res.Body)
		t.Fatalf("oauth authorize expected 302, got %d: %s", res.StatusCode, string(b))
	}
	loc, _ := url.Parse(res.Header.Get("Location"))
	res.Body.Close()
	authCode := loc.Query().Get("code")
	if !strings.HasPrefix(authCode, "nroc_") {
		t.Fatalf("missing auth code in redirect: %s", loc.String())
	}

	// Token exchange
	res, _ = http.PostForm(srv.URL+"/oauth/token", url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {boot.ClientID},
		"code":          {authCode},
		"redirect_uri":  {boot.RedirectURI},
		"code_verifier": {verifier},
	})
	if res.StatusCode != 200 {
		t.Fatalf("oauth token exchange status %d", res.StatusCode)
	}
	var tokResp struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	_ = json.NewDecoder(res.Body).Decode(&tokResp)
	res.Body.Close()
	if !strings.HasPrefix(tokResp.AccessToken, "nro_") || !strings.HasPrefix(tokResp.RefreshToken, "nrr_") {
		t.Fatalf("unexpected token response: %+v", tokResp)
	}

	// /oauth/userinfo works with OAuth access token
	req, _ = http.NewRequest("GET", srv.URL+"/oauth/userinfo", nil)
	req.Header.Set("Authorization", "Bearer "+tokResp.AccessToken)
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != 200 {
		t.Fatalf("userinfo expected 200, got %d", res.StatusCode)
	}
	res.Body.Close()

	// Refresh rotation invalidates old refresh token
	res, _ = http.PostForm(srv.URL+"/oauth/token", url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {boot.ClientID},
		"refresh_token": {tokResp.RefreshToken},
	})
	if res.StatusCode != 200 {
		t.Fatalf("refresh expected 200, got %d", res.StatusCode)
	}
	res.Body.Close()

	res, _ = http.PostForm(srv.URL+"/oauth/token", url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {boot.ClientID},
		"refresh_token": {tokResp.RefreshToken},
	})
	if res.StatusCode != 400 {
		t.Fatalf("expected 400 reusing rotated refresh token, got %d", res.StatusCode)
	}
	res.Body.Close()
}

var _ = bytes.Compare
var _ = filepath.Join
