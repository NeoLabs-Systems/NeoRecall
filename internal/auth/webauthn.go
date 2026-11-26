package auth

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/webauthnx"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

// Security keys run on neolabs-go/webauthnx; this file is NeoRecall's storage
// for it. A challenge is kept server side because clients hold bearer tokens,
// not a cookie session.

const (
	rpName             = "NeoRecall"
	purposeRegister    = "registration"
	purposeAuthenticat = "authentication"
)

func (s *Service) webauthn() *webauthnx.Service {
	c := s.cfg()
	return &webauthnx.Service{
		RPName: rpName, Origins: httpx.ParseOrigins(c.AllowedOrigins), TrustProxy: c.TrustProxy,
		Store: credentialStore{s}, Accounts: webauthnAccounts{s},
	}
}

func ceremonyError(err error) error {
	var failure *webauthnx.Error
	if errors.As(err, &failure) {
		return httperr.New(failure.Status, "SECURITY_KEY_ERROR", failure.Message)
	}
	return err
}

type webauthnAccounts struct{ s *Service }

func (a webauthnAccounts) lookup(ctx context.Context, where string, args ...any) (webauthnx.Identity, bool, error) {
	var id webauthnx.Identity
	var email sql.NullString
	err := a.s.DB.R.QueryRowContext(ctx, `SELECT id, username, email FROM users WHERE `+where, args...).Scan(&id.ID, &id.Username, &email)
	if errors.Is(err, sql.ErrNoRows) {
		return id, false, nil
	}
	id.Email = email.String
	return id, err == nil, err
}

func (a webauthnAccounts) ByID(ctx context.Context, userID string) (webauthnx.Identity, bool, error) {
	return a.lookup(ctx, `id = ?`, userID)
}

func (a webauthnAccounts) ForSignIn(ctx context.Context, identifier string) (webauthnx.Identity, bool, error) {
	return a.lookup(ctx, `username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`, identifier, identifier)
}

type credentialStore struct{ s *Service }

const credentialColumns = `rowid, user_id, credential_id, public_key, counter, rp_id, transports,
	COALESCE(device_type, ''), backed_up, user_verified, label, created_at, COALESCE(last_used_at, '')`

func (c credentialStore) query(ctx context.Context, where string, args ...any) ([]webauthnx.Credential, error) {
	rows, err := c.s.DB.R.QueryContext(ctx, `SELECT `+credentialColumns+` FROM user_webauthn_credentials WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []webauthnx.Credential
	for rows.Next() {
		var cred webauthnx.Credential
		var transports string
		if err := rows.Scan(&cred.RowID, &cred.UserID, &cred.CredentialID, &cred.PublicKey, &cred.Counter, &cred.RPID, &transports,
			&cred.DeviceType, &cred.BackedUp, &cred.UserVerified, &cred.Label, &cred.CreatedAt, &cred.LastUsedAt); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(transports), &cred.Transports)
		out = append(out, cred)
	}
	return out, rows.Err()
}

func (c credentialStore) ListForUser(ctx context.Context, userID string) ([]webauthnx.Credential, error) {
	return c.query(ctx, `user_id = ? ORDER BY created_at DESC`, userID)
}

func (c credentialStore) ForUserAndRP(ctx context.Context, userID, rpID string) ([]webauthnx.Credential, error) {
	return c.query(ctx, `user_id = ? AND rp_id = ?`, userID, rpID)
}

func (c credentialStore) CountForRP(ctx context.Context, rpID string) (int, error) {
	var n int
	err := c.s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM user_webauthn_credentials WHERE rp_id = ?`, rpID).Scan(&n)
	return n, err
}

func (c credentialStore) FindByCredentialID(ctx context.Context, credentialID, rpID string) (*webauthnx.Credential, error) {
	found, err := c.query(ctx, `credential_id = ? AND rp_id = ?`, credentialID, rpID)
	if err != nil || len(found) == 0 {
		return nil, err
	}
	return &found[0], nil
}

func (c credentialStore) Exists(ctx context.Context, credentialID string) (bool, error) {
	found, err := c.query(ctx, `credential_id = ?`, credentialID)
	return len(found) > 0, err
}

func (c credentialStore) Insert(ctx context.Context, cred webauthnx.Credential) error {
	transports, err := json.Marshal(cred.Transports)
	if err != nil {
		return err
	}
	_, err = c.s.DB.W.ExecContext(ctx, `INSERT INTO user_webauthn_credentials
		(id, user_id, credential_id, public_key, counter, rp_id, transports, device_type, backed_up, user_verified, label)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		uuid.NewString(), cred.UserID, cred.CredentialID, cred.PublicKey, cred.Counter, cred.RPID, string(transports),
		cred.DeviceType, cred.BackedUp, cred.UserVerified, cred.Label)
	return err
}

func (c credentialStore) UpdateAfterLogin(ctx context.Context, rowID int64, counter uint32, userVerified bool) error {
	_, err := c.s.DB.W.ExecContext(ctx, `UPDATE user_webauthn_credentials SET counter = ?, user_verified = ?,
		last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE rowid = ?`, counter, userVerified, rowID)
	return err
}

func (c credentialStore) changed(ctx context.Context, query string, args ...any) (bool, error) {
	res, err := c.s.DB.W.ExecContext(ctx, query, args...)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

func (c credentialStore) Rename(ctx context.Context, userID string, rowID int64, label string) (bool, error) {
	return c.changed(ctx, `UPDATE user_webauthn_credentials SET label = ? WHERE rowid = ? AND user_id = ?`, label, rowID, userID)
}

func (c credentialStore) Delete(ctx context.Context, userID string, rowID int64) (bool, error) {
	return c.changed(ctx, `DELETE FROM user_webauthn_credentials WHERE rowid = ? AND user_id = ?`, rowID, userID)
}

func (s *Service) savePending(ctx context.Context, purpose, userID string, pending *webauthnx.Pending) (string, error) {
	raw, err := json.Marshal(pending)
	if err != nil {
		return "", err
	}
	id := uuid.NewString()
	if _, err := s.DB.W.ExecContext(ctx, `DELETE FROM webauthn_challenges WHERE expires_at <= ?`, timeutil.NowISO()); err != nil {
		return "", err
	}
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO webauthn_challenges (id, purpose, user_id, challenge, rp_id, origin, expires_at)
		VALUES (?, ?, ?, ?, ?, '', ?)`,
		id, purpose, nullableStr(userID), string(raw), pending.RPID, timeutil.FormatISO(time.UnixMilli(pending.ExpiresAt)))
	return id, err
}

// takePending spends a challenge: it can be answered once.
func (s *Service) takePending(ctx context.Context, id, purpose, userID string) (*webauthnx.Pending, error) {
	var raw string
	err := s.DB.W.QueryRowContext(ctx, `DELETE FROM webauthn_challenges
		WHERE id = ? AND purpose = ? AND COALESCE(user_id, '') = ? RETURNING challenge`,
		strings.TrimSpace(id), purpose, userID).Scan(&raw)
	var pending webauthnx.Pending
	if err == nil {
		err = json.Unmarshal([]byte(raw), &pending)
	}
	if err != nil {
		return nil, httperr.New(http.StatusBadRequest, "CHALLENGE_EXPIRED", "The security key request expired. Please try again.")
	}
	return &pending, nil
}

func (s *Service) ListWebAuthnCredentials(ctx context.Context, userID string) ([]webauthnx.Payload, error) {
	out, err := s.webauthn().List(ctx, userID)
	return out, ceremonyError(err)
}

func (s *Service) BeginWebAuthnRegistration(ctx context.Context, r *http.Request, userID string) (string, any, error) {
	options, pending, err := s.webauthn().BeginRegistration(ctx, r, userID)
	if err != nil {
		return "", nil, ceremonyError(err)
	}
	id, err := s.savePending(ctx, purposeRegister, userID, pending)
	return id, options, err
}

func (s *Service) CompleteWebAuthnRegistration(ctx context.Context, r *http.Request, userID, challengeID string, response json.RawMessage, label string) ([]webauthnx.Payload, error) {
	pending, err := s.takePending(ctx, challengeID, purposeRegister, userID)
	if err != nil {
		return nil, err
	}
	if err := s.webauthn().CompleteRegistration(ctx, r, userID, response, label, pending); err != nil {
		return nil, ceremonyError(err)
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: "security_key_registered"})
	return s.ListWebAuthnCredentials(ctx, userID)
}

func (s *Service) BeginWebAuthnAuthentication(ctx context.Context, r *http.Request, account string) (string, any, error) {
	options, pending, err := s.webauthn().BeginLogin(ctx, r, account)
	if err != nil {
		return "", nil, ceremonyError(err)
	}
	id, err := s.savePending(ctx, purposeAuthenticat, "", pending)
	return id, options, err
}

func (s *Service) CompleteWebAuthnAuthentication(ctx context.Context, r *http.Request, challengeID string, response json.RawMessage, twoFactorCode string, rc RequestContext) (User, SessionToken, error) {
	pending, err := s.takePending(ctx, challengeID, purposeAuthenticat, "")
	if err != nil {
		return User{}, SessionToken{}, err
	}
	result, err := s.webauthn().CompleteLogin(ctx, r, response, pending)
	if err != nil {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "security_key_login_failed", IPAddress: rc.IPAddress})
		return User{}, SessionToken{}, ceremonyError(err)
	}
	// A key that checked a PIN or biometric already counts as two factors.
	if !result.UserVerified {
		if err := s.VerifySecondFactor(ctx, result.UserID, twoFactorCode); err != nil {
			return User{}, SessionToken{}, err
		}
	}
	return s.signIn(ctx, result.UserID, "security_key_login_succeeded", rc)
}

func (s *Service) RenameWebAuthnCredential(ctx context.Context, userID string, rowID int64, label string) ([]webauthnx.Payload, error) {
	out, err := s.webauthn().Rename(ctx, userID, rowID, label)
	return out, ceremonyError(err)
}

func (s *Service) DeleteWebAuthnCredential(ctx context.Context, userID string, rowID int64) ([]webauthnx.Payload, error) {
	out, err := s.webauthn().Delete(ctx, userID, rowID)
	if err != nil {
		return nil, ceremonyError(err)
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: "security_key_removed"})
	return out, nil
}
