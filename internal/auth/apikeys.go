package auth

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

var AllowedScopes = map[string]bool{
	"ingest:write":     true,
	"devices:read":     true,
	"devices:write":    true,
	"recordings:read":  true,
	"recordings:write": true,
	"memories:read":    true,
	"memories:write":   true,
	"speakers:read":    true,
	"speakers:write":   true,
	"search:read":      true,
	"search:ask":       true,
	"settings:read":    true,
	"settings:write":   true,
	"*":                true,
}

type CreatedAPIKey struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Scopes    []string `json:"scopes"`
	ExpiresAt *string  `json:"expiresAt"`
	Token     string   `json:"token"`
	Prefix    string   `json:"prefix"`
}

type APIKeyView struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Prefix     string   `json:"prefix"`
	Scopes     []string `json:"scopes"`
	ExpiresAt  *string  `json:"expires_at"`
	RevokedAt  *string  `json:"revoked_at"`
	CreatedAt  string   `json:"created_at"`
	LastUsedAt *string  `json:"last_used_at"`
}

func normalizeScopes(scopes []string) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, s := range scopes {
		if !AllowedScopes[s] {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_SCOPES", "One or more API key scopes are invalid.")
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_SCOPES", "One or more API key scopes are invalid.")
	}
	return out, nil
}

func (s *Service) CreateAPIKey(ctx context.Context, userID, name string, scopes []string, expiresAt *string) (CreatedAPIKey, error) {
	normScopes, err := normalizeScopes(scopes)
	if err != nil {
		return CreatedAPIKey{}, err
	}
	secret, err := crypto.RandomToken(32)
	if err != nil {
		return CreatedAPIKey{}, err
	}
	prefix, err := crypto.RandomToken(6)
	if err != nil {
		return CreatedAPIKey{}, err
	}
	token := "nrk_" + prefix + "_" + secret
	id := uuid.NewString()
	scopesJSON, _ := json.Marshal(normScopes)
	var exp sql.NullString
	if expiresAt != nil && *expiresAt != "" {
		exp = sql.NullString{String: *expiresAt, Valid: true}
	}
	trimmedName := strings.TrimSpace(name)
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO api_keys
		(id, user_id, name, key_prefix, key_hash, scopes_json, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, userID, trimmedName, prefix, crypto.SHA256Hex(token), string(scopesJSON), exp)
	if err != nil {
		return CreatedAPIKey{}, err
	}
	return CreatedAPIKey{ID: id, Name: trimmedName, Scopes: normScopes, ExpiresAt: expiresAt, Token: token, Prefix: prefix}, nil
}

func (s *Service) ListAPIKeys(ctx context.Context, userID string) ([]APIKeyView, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, name, key_prefix, scopes_json, expires_at, revoked_at, created_at, last_used_at
		FROM api_keys WHERE user_id = ? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []APIKeyView{}
	for rows.Next() {
		var k APIKeyView
		var scopesJSON string
		var exp, rev, last sql.NullString
		if err := rows.Scan(&k.ID, &k.Name, &k.Prefix, &scopesJSON, &exp, &rev, &k.CreatedAt, &last); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(scopesJSON), &k.Scopes)
		k.ExpiresAt = nullPtr(exp)
		k.RevokedAt = nullPtr(rev)
		k.LastUsedAt = nullPtr(last)
		out = append(out, k)
	}
	return out, rows.Err()
}

func (s *Service) RevokeAPIKey(ctx context.Context, userID, id string) error {
	res, err := s.DB.W.ExecContext(ctx, `UPDATE api_keys SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id = ? AND user_id = ? AND revoked_at IS NULL`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "API key not found.")
	}
	return nil
}

// AuthenticateAPIKey validates an nrk_ token.
func (s *Service) AuthenticateAPIKey(ctx context.Context, token string) *AuthContext {
	if !strings.HasPrefix(token, "nrk_") {
		return nil
	}
	now := timeutil.NowISO()
	var id, userID, scopesJSON, username, role, createdAt string
	var email, disabledAt sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT k.id, k.user_id, k.scopes_json, u.username, u.email, u.role, u.disabled_at, u.created_at
		FROM api_keys k JOIN users u ON u.id = k.user_id
		WHERE k.key_hash = ? AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at > ?)`,
		crypto.SHA256Hex(token), now).Scan(&id, &userID, &scopesJSON, &username, &email, &role, &disabledAt, &createdAt)
	if err != nil || (disabledAt.Valid && disabledAt.String != "") {
		return nil
	}
	var scopes []string
	_ = json.Unmarshal([]byte(scopesJSON), &scopes)
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE api_keys SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, id)
	return &AuthContext{
		Type:     "api_key",
		APIKeyID: id,
		UserID:   userID,
		Scopes:   scopes,
		User:     User{ID: userID, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt},
	}
}
