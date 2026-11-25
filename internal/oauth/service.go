// Package oauth implements NeoRecall's OAuth 2.0 Authorization Server with
// PKCE (S256), RFC 7591 dynamic client registration, NeoAgent companion
// bootstrap, browser sign-in/consent pages, token refresh rotation, and user
// grant revocation (/api/v1/integrations).
package oauth

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/oauthclient"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

var (
	Scopes = []string{"search:read", "memories:read", "recordings:read"}

	AccessTTLSeconds  = int64(60 * 60)
	RefreshTTLSeconds = int64(30 * 24 * 60 * 60)
	CodeTTLSeconds    = int64(10 * 60)

	stateRe     = regexp.MustCompile(`^[A-Za-z0-9._~-]+$`)
	challengeRe = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	priv172Re   = regexp.MustCompile(`^172\.(1[6-9]|2\d|3[01])\.`)
)

type Service struct {
	DB        *dbx.DB
	Auth      *auth.Service
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

type Client struct {
	ID           string
	Name         string
	Description  string
	ClientType   string
	RedirectURIs []string
	Scopes       []string
	CreatedAt    string
}

type AuthorizeRequest struct {
	Client        Client
	RedirectURI   string
	State         string
	CodeChallenge string
	Scopes        []string
}

type TokenSet struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    int64
	Scope        string
	RefreshID    string
}

type UserIntegration struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Description *string `json:"description"`
	CreatedAt   string  `json:"created_at"`
	LastUsedAt  *string `json:"last_used_at"`
}

func parseJSONArray(raw string) []string {
	var arr []string
	if err := json.Unmarshal([]byte(raw), &arr); err != nil || arr == nil {
		return []string{}
	}
	return arr
}

func parseScopes(requested []string) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, sc := range requested {
		sc = strings.TrimSpace(sc)
		if sc == "" {
			continue
		}
		if !slices.Contains(Scopes, sc) {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_SCOPE", "Invalid OAuth scope.")
		}
		if !seen[sc] {
			seen[sc] = true
			out = append(out, sc)
		}
	}
	if len(out) == 0 {
		return append([]string(nil), Scopes...), nil
	}
	return out, nil
}

func isPrivateOrLoopbackHost(host string) bool {
	h := strings.Trim(strings.ToLower(host), "[]")
	if i := strings.IndexByte(h, '%'); i >= 0 {
		h = h[:i]
	}
	if h == "localhost" || h == "::1" || strings.HasPrefix(h, "127.") || strings.HasPrefix(h, "10.") || strings.HasPrefix(h, "192.168.") || priv172Re.MatchString(h) {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}

func CanonicalizeRedirectURI(raw string, requireNeoAgentPath bool) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "", httperr.New(http.StatusBadRequest, "INVALID_REDIRECT_URI", "redirect_uri must be a valid HTTP or HTTPS URL.")
	}
	scheme := strings.ToLower(u.Scheme)
	if (scheme != "http" && scheme != "https") || u.Fragment != "" || (scheme == "http" && !isPrivateOrLoopbackHost(u.Hostname())) {
		return "", httperr.New(http.StatusBadRequest, "INVALID_REDIRECT_URI", "redirect_uri must be HTTPS, or HTTP on a private/loopback address.")
	}
	if requireNeoAgentPath && (u.RawQuery != "" || u.Path != "/api/integrations/oauth/callback") {
		return "", httperr.New(http.StatusBadRequest, "INVALID_REDIRECT_URI", "redirectUri must be an HTTPS NeoAgent callback, or HTTP on a private/loopback address.")
	}
	return u.String(), nil
}

func (s *Service) activeClient(ctx context.Context, clientID string) (Client, error) {
	var c Client
	var desc sql.NullString
	var redirJSON, scopesJSON string
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, name, description, client_type, redirect_uris_json, scopes_json, created_at
		FROM oauth_clients WHERE id = ? AND revoked_at IS NULL`, strings.TrimSpace(clientID)).
		Scan(&c.ID, &c.Name, &desc, &c.ClientType, &redirJSON, &scopesJSON, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Client{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "OAuth client not found.")
	}
	if err != nil {
		return Client{}, err
	}
	c.Description = desc.String
	c.RedirectURIs = parseJSONArray(redirJSON)
	c.Scopes = parseJSONArray(scopesJSON)
	return c, nil
}

func validateRedirectURI(c Client, uri string) (string, error) {
	v := strings.TrimSpace(uri)
	if v == "" || !slices.Contains(c.RedirectURIs, v) {
		return "", httperr.New(http.StatusBadRequest, "INVALID_REDIRECT_URI", "Invalid redirect_uri.")
	}
	return v, nil
}

func (s *Service) CreateCompanionClient(ctx context.Context, redirectURI, appName string) (Client, bool, error) {
	if strings.TrimSpace(appName) != "" && strings.TrimSpace(appName) != "NeoAgent" {
		return Client{}, false, httperr.New(http.StatusBadRequest, "INVALID_COMPANION", "Only the NeoAgent companion is supported.")
	}
	canon, err := CanonicalizeRedirectURI(redirectURI, true)
	if err != nil {
		return Client{}, false, err
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, name, description, client_type, redirect_uris_json, scopes_json, created_at
		FROM oauth_clients WHERE description='companion:neoagent' AND client_type='public' AND revoked_at IS NULL`)
	if err != nil {
		return Client{}, false, err
	}
	for rows.Next() {
		var c Client
		var desc sql.NullString
		var redirJSON, scopesJSON string
		if err := rows.Scan(&c.ID, &c.Name, &desc, &c.ClientType, &redirJSON, &scopesJSON, &c.CreatedAt); err != nil {
			rows.Close()
			return Client{}, false, err
		}
		c.Description = desc.String
		c.RedirectURIs = parseJSONArray(redirJSON)
		c.Scopes = parseJSONArray(scopesJSON)
		if len(c.RedirectURIs) == 1 && c.RedirectURIs[0] == canon && slices.Equal(c.Scopes, Scopes) {
			rows.Close()
			return c, false, nil
		}
	}
	rows.Close()

	suffix, err := crypto.RandomToken(18)
	if err != nil {
		return Client{}, false, err
	}
	id := "nrc_" + suffix
	redirB, _ := json.Marshal([]string{canon})
	scopesB, _ := json.Marshal(Scopes)
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO oauth_clients
		(id, name, description, client_type, redirect_uris_json, scopes_json) VALUES (?, ?, ?, ?, ?, ?)`,
		id, "NeoAgent", "companion:neoagent", "public", string(redirB), string(scopesB)); err != nil {
		return Client{}, false, err
	}
	c, err := s.activeClient(ctx, id)
	return c, true, err
}

func sanitizeClientName(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if r >= 0x20 && r != 0x7f {
			b.WriteRune(r)
		}
	}
	name := strings.TrimSpace(b.String())
	if len([]rune(name)) > 80 {
		name = string([]rune(name)[:80])
	}
	if name == "" {
		return "MCP client"
	}
	return name
}

type RegisterRequest struct {
	ClientName              string   `json:"client_name"`
	TokenEndpointAuthMethod string   `json:"token_endpoint_auth_method"`
	GrantTypes              []string `json:"grant_types"`
	RedirectURIs            []string `json:"redirect_uris"`
	Scope                   string   `json:"scope"`
}

func (s *Service) RegisterPublicClient(ctx context.Context, req RegisterRequest) (map[string]any, error) {
	method := strings.TrimSpace(req.TokenEndpointAuthMethod)
	if method == "" {
		method = "none"
	}
	if method != "none" {
		return nil, httperr.New(http.StatusBadRequest, "invalid_client_metadata", "Only public clients (token_endpoint_auth_method=none) are supported.")
	}
	grants := req.GrantTypes
	if len(grants) == 0 {
		grants = []string{"authorization_code", "refresh_token"}
	}
	for _, g := range grants {
		if g != "authorization_code" && g != "refresh_token" {
			return nil, httperr.New(http.StatusBadRequest, "invalid_client_metadata", "Unsupported grant_type.")
		}
	}
	if len(req.RedirectURIs) == 0 || len(req.RedirectURIs) > 8 {
		return nil, httperr.New(http.StatusBadRequest, "invalid_client_metadata", "redirect_uris must contain 1–8 URIs.")
	}
	seenUris := map[string]bool{}
	var redirs []string
	for _, raw := range req.RedirectURIs {
		c, err := CanonicalizeRedirectURI(raw, false)
		if err != nil {
			return nil, httperr.New(http.StatusBadRequest, "invalid_client_metadata", err.Error())
		}
		if !seenUris[c] {
			seenUris[c] = true
			redirs = append(redirs, c)
		}
	}
	var reqScopes []string
	if strings.TrimSpace(req.Scope) != "" {
		reqScopes = strings.Fields(req.Scope)
	}
	scopes, err := parseScopes(reqScopes)
	if err != nil {
		return nil, httperr.New(http.StatusBadRequest, "invalid_client_metadata", err.Error())
	}
	name := sanitizeClientName(req.ClientName)
	suffix, err := crypto.RandomToken(18)
	if err != nil {
		return nil, err
	}
	id := "nrc_" + suffix
	redirB, _ := json.Marshal(redirs)
	scopesB, _ := json.Marshal(scopes)
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO oauth_clients
		(id, name, description, client_type, redirect_uris_json, scopes_json) VALUES (?, ?, ?, ?, ?, ?)`,
		id, name, "mcp:dcr", "public", string(redirB), string(scopesB)); err != nil {
		return nil, err
	}
	c, err := s.activeClient(ctx, id)
	if err != nil {
		return nil, err
	}
	issuedAt, _ := timeutil.ParseISO(c.CreatedAt)
	return map[string]any{
		"client_id":                  c.ID,
		"client_id_issued_at":        issuedAt.Unix(),
		"client_name":                c.Name,
		"redirect_uris":              redirs,
		"token_endpoint_auth_method": "none",
		"grant_types":                []string{"authorization_code", "refresh_token"},
		"response_types":             []string{"code"},
		"scope":                      strings.Join(scopes, " "),
	}, nil
}

func (s *Service) ListUserIntegrations(ctx context.Context, userID string) ([]UserIntegration, error) {
	now := timeutil.NowISO()
	rows, err := s.DB.R.QueryContext(ctx, `SELECT c.id, c.name, c.description, c.created_at,
		(SELECT MAX(t.last_used_at) FROM oauth_access_tokens t WHERE t.client_id=c.id AND t.user_id=?) AS last_used_at
		FROM oauth_clients c
		WHERE c.revoked_at IS NULL
		  AND (
			EXISTS (SELECT 1 FROM oauth_access_tokens t WHERE t.client_id=c.id AND t.user_id=? AND t.revoked_at IS NULL AND t.expires_at>?)
			OR EXISTS (SELECT 1 FROM oauth_refresh_tokens r WHERE r.client_id=c.id AND r.user_id=? AND r.revoked_at IS NULL AND r.expires_at>?)
		  )
		ORDER BY c.name COLLATE NOCASE, c.created_at`, userID, userID, now, userID, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []UserIntegration{}
	for rows.Next() {
		var u UserIntegration
		var desc, last sql.NullString
		if err := rows.Scan(&u.ID, &u.Name, &desc, &u.CreatedAt, &last); err != nil {
			return nil, err
		}
		if desc.Valid {
			d := desc.String
			u.Description = &d
		}
		if last.Valid {
			l := last.String
			u.LastUsedAt = &l
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Service) RevokeUserClient(ctx context.Context, userID, clientID string) error {
	var id string
	err := s.DB.R.QueryRowContext(ctx, `SELECT id FROM oauth_clients WHERE id = ? AND revoked_at IS NULL`, strings.TrimSpace(clientID)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "OAuth client not found.")
	}
	if err != nil {
		return err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	r1, err := tx.ExecContext(ctx, `UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND user_id=? AND revoked_at IS NULL`, id, userID)
	if err != nil {
		return err
	}
	r2, err := tx.ExecContext(ctx, `UPDATE oauth_refresh_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND user_id=? AND revoked_at IS NULL`, id, userID)
	if err != nil {
		return err
	}
	a1, _ := r1.RowsAffected()
	a2, _ := r2.RowsAffected()
	if a1+a2 == 0 {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "OAuth client not found.")
	}
	return tx.Commit()
}

func (s *Service) ValidateAuthorizationRequest(ctx context.Context, responseType, clientID, redirectURI, state, codeChallenge, codeChallengeMethod, scope string) (AuthorizeRequest, error) {
	if strings.TrimSpace(responseType) != "code" {
		return AuthorizeRequest{}, httperr.New(http.StatusBadRequest, "UNSUPPORTED_RESPONSE_TYPE", "Unsupported response_type.")
	}
	client, err := s.activeClient(ctx, clientID)
	if err != nil {
		return AuthorizeRequest{}, err
	}
	redir, err := validateRedirectURI(client, redirectURI)
	if err != nil {
		return AuthorizeRequest{}, err
	}
	st := strings.TrimSpace(state)
	cc := strings.TrimSpace(codeChallenge)
	if len(st) < 16 || len(st) > 512 || !stateRe.MatchString(st) || !challengeRe.MatchString(cc) || strings.ToUpper(strings.TrimSpace(codeChallengeMethod)) != "S256" {
		return AuthorizeRequest{}, httperr.New(http.StatusBadRequest, "INVALID_REQUEST", "state and PKCE S256 are required.")
	}
	var reqScopes []string
	if strings.TrimSpace(scope) != "" {
		reqScopes = strings.Fields(scope)
	}
	scopes, err := parseScopes(reqScopes)
	if err != nil {
		return AuthorizeRequest{}, err
	}
	for _, sc := range scopes {
		if !slices.Contains(client.Scopes, sc) {
			return AuthorizeRequest{}, httperr.New(http.StatusBadRequest, "INVALID_SCOPE", "Requested scope is not allowed.")
		}
	}
	return AuthorizeRequest{Client: client, RedirectURI: redir, State: st, CodeChallenge: cc, Scopes: scopes}, nil
}

type browserGrant struct {
	Version   int    `json:"version"`
	UserID    string `json:"userId"`
	ExpiresAt int64  `json:"expiresAt"`
}

func (s *Service) CreateBrowserGrant(userID string) (string, error) {
	key, err := s.MasterKey()
	if err != nil {
		return "", err
	}
	ttl := s.cfg().OAuthBrowserGrantTTLMs
	if ttl <= 0 {
		ttl = 15 * 60_000
	}
	raw, _ := json.Marshal(browserGrant{Version: 1, UserID: userID, ExpiresAt: time.Now().UnixMilli() + ttl})
	return crypto.EncryptString(key, string(raw))
}

func (s *Service) AuthenticateBrowserGrant(ctx context.Context, value string) *auth.User {
	if value == "" {
		return nil
	}
	key, err := s.MasterKey()
	if err != nil {
		return nil
	}
	plain, err := crypto.DecryptString(key, value)
	if err != nil {
		return nil
	}
	var g browserGrant
	if json.Unmarshal([]byte(plain), &g) != nil || g.Version != 1 || time.Now().UnixMilli() >= g.ExpiresAt {
		return nil
	}
	var disabled sql.NullString
	var u auth.User
	var email sql.NullString
	err = s.DB.R.QueryRowContext(ctx, `SELECT id, username, email, role, created_at, disabled_at FROM users WHERE id = ?`, g.UserID).
		Scan(&u.ID, &u.Username, &email, &u.Role, &u.CreatedAt, &disabled)
	if err != nil || (disabled.Valid && disabled.String != "") {
		return nil
	}
	if email.Valid {
		e := email.String
		u.Email = &e
	}
	return &u
}

type pending2FAGrant struct {
	Version   int    `json:"version"`
	Purpose   string `json:"purpose"`
	UserID    string `json:"userId"`
	Account   string `json:"account"`
	ExpiresAt int64  `json:"expiresAt"`
}

func (s *Service) CreatePendingTwoFactorGrant(userID, account string) (string, error) {
	key, err := s.MasterKey()
	if err != nil {
		return "", err
	}
	ttl := s.cfg().OAuthPendingTwoFactorTTLMs
	if ttl <= 0 {
		ttl = 5 * 60_000
	}
	raw, _ := json.Marshal(pending2FAGrant{
		Version: 2, Purpose: "oauth_2fa", UserID: userID, Account: account,
		ExpiresAt: time.Now().UnixMilli() + ttl,
	})
	return crypto.EncryptString(key, string(raw))
}

func (s *Service) AuthenticatePendingTwoFactorGrant(ctx context.Context, value string) (userID, account string, ok bool) {
	if value == "" {
		return "", "", false
	}
	key, err := s.MasterKey()
	if err != nil {
		return "", "", false
	}
	plain, err := crypto.DecryptString(key, value)
	if err != nil {
		return "", "", false
	}
	var g pending2FAGrant
	if json.Unmarshal([]byte(plain), &g) != nil || g.Version != 2 || g.Purpose != "oauth_2fa" || time.Now().UnixMilli() >= g.ExpiresAt {
		return "", "", false
	}
	var username string
	var disabled sql.NullString
	if err := s.DB.R.QueryRowContext(ctx, `SELECT username, disabled_at FROM users WHERE id = ?`, g.UserID).Scan(&username, &disabled); err != nil {
		return "", "", false
	}
	if disabled.Valid && disabled.String != "" {
		return "", "", false
	}
	acct := g.Account
	if acct == "" {
		acct = username
	}
	return g.UserID, acct, true
}

func (s *Service) CreateAuthorizationCode(ctx context.Context, clientID, userID, redirectURI string, scopes []string, codeChallenge string) (string, error) {
	suffix, err := crypto.RandomToken(32)
	if err != nil {
		return "", err
	}
	code := "nroc_" + suffix
	scopesB, _ := json.Marshal(scopes)
	expires := timeutil.FormatISO(time.Now().Add(time.Duration(CodeTTLSeconds) * time.Second))
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO oauth_authorization_codes
		(id, client_id, user_id, code_hash, redirect_uri, scopes_json, code_challenge, code_challenge_method, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'S256', ?)`,
		uuid.NewString(), clientID, userID, crypto.SHA256Hex(code), redirectURI, string(scopesB), codeChallenge, expires)
	if err != nil {
		return "", err
	}
	return code, nil
}

func verifyPKCE(verifier, challenge string) bool {
	return oauthclient.CodeChallenge(verifier) == challenge
}

func (s *Service) issueTokenSet(ctx context.Context, tx *sql.Tx, clientID, userID string, scopes []string) (TokenSet, error) {
	atSuf, err := crypto.RandomToken(32)
	if err != nil {
		return TokenSet{}, err
	}
	rtSuf, err := crypto.RandomToken(32)
	if err != nil {
		return TokenSet{}, err
	}
	at := "nro_" + atSuf
	rt := "nrr_" + rtSuf
	accessID := uuid.NewString()
	refreshID := uuid.NewString()
	scopesB, _ := json.Marshal(scopes)
	now := time.Now()
	if _, err := tx.ExecContext(ctx, `INSERT INTO oauth_access_tokens
		(id, client_id, user_id, token_hash, scopes_json, expires_at) VALUES (?, ?, ?, ?, ?, ?)`,
		accessID, clientID, userID, crypto.SHA256Hex(at), string(scopesB), timeutil.FormatISO(now.Add(time.Duration(AccessTTLSeconds)*time.Second))); err != nil {
		return TokenSet{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO oauth_refresh_tokens
		(id, access_token_id, client_id, user_id, token_hash, scopes_json, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		refreshID, accessID, clientID, userID, crypto.SHA256Hex(rt), string(scopesB), timeutil.FormatISO(now.Add(time.Duration(RefreshTTLSeconds)*time.Second))); err != nil {
		return TokenSet{}, err
	}
	return TokenSet{AccessToken: at, RefreshToken: rt, ExpiresIn: AccessTTLSeconds, Scope: strings.Join(scopes, " "), RefreshID: refreshID}, nil
}

func (s *Service) ExchangeAuthorizationCode(ctx context.Context, clientID, code, redirectURI, codeVerifier string) (TokenSet, error) {
	c, err := s.activeClient(ctx, clientID)
	if err != nil {
		return TokenSet{}, err
	}
	normRedir, err := validateRedirectURI(c, redirectURI)
	if err != nil {
		return TokenSet{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return TokenSet{}, err
	}
	defer tx.Rollback()

	var rowID, userID, rowRedir, scopesJSON, challenge string
	err = tx.QueryRowContext(ctx, `SELECT id, user_id, redirect_uri, scopes_json, code_challenge
		FROM oauth_authorization_codes WHERE code_hash=? AND client_id=? AND consumed_at IS NULL AND expires_at>?`,
		crypto.SHA256Hex(code), c.ID, timeutil.NowISO()).Scan(&rowID, &userID, &rowRedir, &scopesJSON, &challenge)
	if err != nil || rowRedir != normRedir || !verifyPKCE(codeVerifier, challenge) {
		return TokenSet{}, httperr.New(http.StatusBadRequest, "invalid_grant", "Invalid authorization code.")
	}
	res, err := tx.ExecContext(ctx, `UPDATE oauth_authorization_codes SET consumed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND consumed_at IS NULL`, rowID)
	if err != nil {
		return TokenSet{}, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return TokenSet{}, httperr.New(http.StatusBadRequest, "invalid_grant", "Invalid authorization code.")
	}
	ts, err := s.issueTokenSet(ctx, tx, c.ID, userID, parseJSONArray(scopesJSON))
	if err != nil {
		return TokenSet{}, err
	}
	if err := tx.Commit(); err != nil {
		return TokenSet{}, err
	}
	return ts, nil
}

func (s *Service) RefreshTokenSet(ctx context.Context, clientID, refreshToken string) (TokenSet, error) {
	c, err := s.activeClient(ctx, clientID)
	if err != nil {
		return TokenSet{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return TokenSet{}, err
	}
	defer tx.Rollback()

	var rowID, accessTokenID, userID, scopesJSON string
	err = tx.QueryRowContext(ctx, `SELECT id, access_token_id, user_id, scopes_json FROM oauth_refresh_tokens
		WHERE token_hash=? AND client_id=? AND revoked_at IS NULL AND expires_at>?`,
		crypto.SHA256Hex(refreshToken), c.ID, timeutil.NowISO()).Scan(&rowID, &accessTokenID, &userID, &scopesJSON)
	if err != nil {
		return TokenSet{}, httperr.New(http.StatusBadRequest, "invalid_grant", "Invalid refresh token.")
	}
	ts, err := s.issueTokenSet(ctx, tx, c.ID, userID, parseJSONArray(scopesJSON))
	if err != nil {
		return TokenSet{}, err
	}
	res, err := tx.ExecContext(ctx, `UPDATE oauth_refresh_tokens SET
		revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), last_used_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
		replaced_by_token_id=? WHERE id=? AND revoked_at IS NULL`, ts.RefreshID, rowID)
	if err != nil {
		return TokenSet{}, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return TokenSet{}, httperr.New(http.StatusBadRequest, "invalid_grant", "Invalid refresh token.")
	}
	_, _ = tx.ExecContext(ctx, `UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, accessTokenID)
	if err := tx.Commit(); err != nil {
		return TokenSet{}, err
	}
	return ts, nil
}

func (s *Service) RevokeToken(ctx context.Context, clientID, token string) error {
	c, err := s.activeClient(ctx, clientID)
	if err != nil {
		return err
	}
	h := crypto.SHA256Hex(token)
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var linkedAccess sql.NullString
	_ = tx.QueryRowContext(ctx, `SELECT access_token_id FROM oauth_refresh_tokens WHERE client_id=? AND token_hash=?`, c.ID, h).Scan(&linkedAccess)
	_, _ = tx.ExecContext(ctx, `UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND token_hash=? AND revoked_at IS NULL`, c.ID, h)
	_, _ = tx.ExecContext(ctx, `UPDATE oauth_refresh_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE client_id=? AND token_hash=? AND revoked_at IS NULL`, c.ID, h)
	if linkedAccess.Valid && linkedAccess.String != "" {
		_, _ = tx.ExecContext(ctx, `UPDATE oauth_access_tokens SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND client_id=? AND revoked_at IS NULL`, linkedAccess.String, c.ID)
	}
	return tx.Commit()
}

// AuthenticateAccessToken resolves an nro_ access token.
func (s *Service) AuthenticateAccessToken(ctx context.Context, token string) *auth.AuthContext {
	if !strings.HasPrefix(token, "nro_") {
		return nil
	}
	now := timeutil.NowISO()
	var id, clientID, userID, scopesJSON, username, role, createdAt, clientName string
	var email, disabledAt sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT t.id, t.client_id, t.user_id, t.scopes_json,
		u.username, u.email, u.role, u.disabled_at, u.created_at, c.name
		FROM oauth_access_tokens t
		JOIN users u ON u.id = t.user_id
		JOIN oauth_clients c ON c.id = t.client_id
		WHERE t.token_hash=? AND t.revoked_at IS NULL AND t.expires_at>? AND c.revoked_at IS NULL`,
		crypto.SHA256Hex(token), now).Scan(&id, &clientID, &userID, &scopesJSON, &username, &email, &role, &disabledAt, &createdAt, &clientName)
	if err != nil || (disabledAt.Valid && disabledAt.String != "") {
		return nil
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE oauth_access_tokens SET last_used_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, id)
	var emailPtr *string
	if email.Valid {
		e := email.String
		emailPtr = &e
	}
	return &auth.AuthContext{
		Type:         "oauth",
		OAuthTokenID: id,
		ClientID:     clientID,
		ClientName:   clientName,
		UserID:       userID,
		Scopes:       parseJSONArray(scopesJSON),
		User:         auth.User{ID: userID, Username: username, Email: emailPtr, Role: role, CreatedAt: createdAt},
	}
}
