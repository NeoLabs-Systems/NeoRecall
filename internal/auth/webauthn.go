package auth

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
)

const (
	rpName                = "NeoRecall"
	challengeTTL          = 5 * time.Minute
	ceremonyTimeout       = 2 * time.Minute
	maxCredentialsPerUser = 20
	maxLabelLen           = 48
)

type RelyingParty struct {
	Origin string
	RPID   string
}

type WebAuthnCredentialView struct {
	ID         string  `json:"id"`
	Label      string  `json:"label"`
	CreatedAt  string  `json:"createdAt"`
	LastUsedAt *string `json:"lastUsedAt"`
	BackedUp   bool    `json:"backedUp"`
	RPID       string  `json:"rpId"`
}

// ResolveRelyingParty derives RPID and allowed Origin identically to Node's webauthn_service.js.
func (s *Service) ResolveRelyingParty(r *http.Request) (RelyingParty, error) {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	} else if s.cfg().TrustProxy {
		if p := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0]); strings.EqualFold(p, "https") {
			scheme = "https"
		}
	}
	selfOrigin := scheme + "://" + r.Host
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		origin = selfOrigin
	}
	allowed := false
	if origin == selfOrigin {
		allowed = true
	} else {
		for _, a := range strings.Split(s.cfg().AllowedOrigins, ",") {
			a = strings.TrimSpace(a)
			if a == "*" || a == origin {
				allowed = true
				break
			}
		}
	}
	if !allowed {
		return RelyingParty{}, httperr.New(http.StatusForbidden, "ORIGIN_NOT_ALLOWED", "Security keys cannot be used from this origin.")
	}
	u, err := url.Parse(origin)
	if err != nil || u.Hostname() == "" {
		return RelyingParty{}, httperr.New(http.StatusBadRequest, "INVALID_ORIGIN", "The request origin is not a valid address.")
	}
	return RelyingParty{Origin: origin, RPID: u.Hostname()}, nil
}

func newWebAuthnClient(rp RelyingParty) (*webauthn.WebAuthn, error) {
	return webauthn.New(&webauthn.Config{
		RPID:                  rp.RPID,
		RPDisplayName:         rpName,
		RPOrigins:             []string{rp.Origin},
		AttestationPreference: protocol.PreferNoAttestation,
		Timeouts: webauthn.TimeoutsConfig{
			Login:        webauthn.TimeoutConfig{Enforce: true, Timeout: ceremonyTimeout, TimeoutUVD: ceremonyTimeout},
			Registration: webauthn.TimeoutConfig{Enforce: true, Timeout: ceremonyTimeout, TimeoutUVD: ceremonyTimeout},
		},
	})
}

func normalizeWebAuthnLabel(val, fallback string) (string, error) {
	label := strings.Join(strings.Fields(val), " ")
	if label == "" {
		return fallback, nil
	}
	if len([]rune(label)) > maxLabelLen {
		return "", httperr.New(http.StatusBadRequest, "INVALID_LABEL", fmt.Sprintf("The security key name may contain at most %d characters.", maxLabelLen))
	}
	return label, nil
}

func (s *Service) ListWebAuthnCredentials(ctx context.Context, userID string) ([]WebAuthnCredentialView, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, label, created_at, last_used_at, backed_up, rp_id
		FROM user_webauthn_credentials WHERE user_id = ? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []WebAuthnCredentialView{}
	for rows.Next() {
		var c WebAuthnCredentialView
		var last sql.NullString
		var backedUp int
		if err := rows.Scan(&c.ID, &c.Label, &c.CreatedAt, &last, &backedUp, &c.RPID); err != nil {
			return nil, err
		}
		c.BackedUp = backedUp == 1
		c.LastUsedAt = nullPtr(last)
		out = append(out, c)
	}
	return out, rows.Err()
}

type waUser struct {
	id          string
	name        string
	credentials []webauthn.Credential
}

func (u waUser) WebAuthnID() []byte                         { return []byte(u.id) }
func (u waUser) WebAuthnName() string                       { return u.name }
func (u waUser) WebAuthnDisplayName() string                { return u.name }
func (u waUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func (s *Service) descriptorsForRP(ctx context.Context, userID, rpID string) ([]protocol.CredentialDescriptor, []webauthn.Credential, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT credential_id, public_key, counter, transports
		FROM user_webauthn_credentials WHERE user_id = ? AND rp_id = ?`, userID, rpID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var descs []protocol.CredentialDescriptor
	var creds []webauthn.Credential
	for rows.Next() {
		var credID, pubKey, transJSON string
		var counter uint32
		if err := rows.Scan(&credID, &pubKey, &counter, &transJSON); err != nil {
			return nil, nil, err
		}
		rawID, err := base64.RawURLEncoding.DecodeString(credID)
		if err != nil {
			continue
		}
		rawPub, err := base64.RawURLEncoding.DecodeString(pubKey)
		if err != nil {
			continue
		}
		var tList []string
		_ = json.Unmarshal([]byte(transJSON), &tList)
		var pt []protocol.AuthenticatorTransport
		for _, t := range tList {
			pt = append(pt, protocol.AuthenticatorTransport(t))
		}
		descs = append(descs, protocol.CredentialDescriptor{
			Type:         protocol.PublicKeyCredentialType,
			CredentialID: rawID,
			Transport:    pt,
		})
		creds = append(creds, webauthn.Credential{
			ID:            rawID,
			PublicKey:     rawPub,
			Transport:     pt,
			Authenticator: webauthn.Authenticator{SignCount: counter},
		})
	}
	return descs, creds, rows.Err()
}

func (s *Service) storeChallenge(ctx context.Context, purpose, userID, challenge string, rp RelyingParty) (string, error) {
	id := uuid.NewString()
	now := time.Now()
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM webauthn_challenges WHERE expires_at <= ?`, timeutil.FormatISO(now))
	_, err := s.DB.W.ExecContext(ctx, `INSERT INTO webauthn_challenges (id, purpose, user_id, challenge, rp_id, origin, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, purpose, nullableStr(userID), challenge, rp.RPID, rp.Origin, timeutil.FormatISO(now.Add(challengeTTL)))
	return id, err
}

func (s *Service) consumeChallenge(ctx context.Context, challengeID, purpose string, rp RelyingParty) (userID, challenge string, err error) {
	var uid sql.NullString
	var rpID, origin, expiresAt string
	err = s.DB.R.QueryRowContext(ctx, `SELECT user_id, challenge, rp_id, origin, expires_at
		FROM webauthn_challenges WHERE id = ? AND purpose = ?`, strings.TrimSpace(challengeID), purpose).
		Scan(&uid, &challenge, &rpID, &origin, &expiresAt)
	if err == nil {
		_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM webauthn_challenges WHERE id = ?`, challengeID)
	}
	exp, perr := timeutil.ParseISO(expiresAt)
	if err != nil || perr != nil || !exp.After(time.Now()) {
		return "", "", httperr.New(http.StatusBadRequest, "CHALLENGE_EXPIRED", "The security key request expired. Please try again.")
	}
	if rpID != rp.RPID || origin != rp.Origin {
		return "", "", httperr.New(http.StatusBadRequest, "CHALLENGE_ORIGIN_MISMATCH", "The security key request was started from a different address.")
	}
	return uid.String, challenge, nil
}

func (s *Service) BeginWebAuthnRegistration(ctx context.Context, userID, username string, rp RelyingParty) (string, any, error) {
	existing, err := s.ListWebAuthnCredentials(ctx, userID)
	if err != nil {
		return "", nil, err
	}
	if len(existing) >= maxCredentialsPerUser {
		return "", nil, httperr.New(http.StatusBadRequest, "TOO_MANY_CREDENTIALS", fmt.Sprintf("At most %d security keys can be registered.", maxCredentialsPerUser))
	}
	descs, _, err := s.descriptorsForRP(ctx, userID, rp.RPID)
	if err != nil {
		return "", nil, err
	}
	wa, err := newWebAuthnClient(rp)
	if err != nil {
		return "", nil, err
	}
	creation, sess, err := wa.BeginRegistration(waUser{id: userID, name: username},
		webauthn.WithExclusions(descs),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementPreferred,
			UserVerification: protocol.VerificationPreferred,
		}))
	if err != nil {
		return "", nil, err
	}
	sessBytes, _ := json.Marshal(sess)
	cid, err := s.storeChallenge(ctx, "registration", userID, string(sessBytes), rp)
	if err != nil {
		return "", nil, err
	}
	return cid, creation.Response, nil
}

func (s *Service) CompleteWebAuthnRegistration(ctx context.Context, userID, challengeID string, rawResponse json.RawMessage, label string, rp RelyingParty) ([]WebAuthnCredentialView, error) {
	cUserID, sessJSON, err := s.consumeChallenge(ctx, challengeID, "registration", rp)
	if err != nil {
		return nil, err
	}
	if cUserID != userID {
		return nil, httperr.New(http.StatusBadRequest, "CHALLENGE_MISMATCH", "The security key request belongs to another account.")
	}
	var sess webauthn.SessionData
	if err := json.Unmarshal([]byte(sessJSON), &sess); err != nil {
		return nil, httperr.New(http.StatusBadRequest, "CHALLENGE_EXPIRED", "The security key request expired. Please try again.")
	}
	wa, err := newWebAuthnClient(rp)
	if err != nil {
		return nil, err
	}
	parsed, perr := protocol.ParseCredentialCreationResponseBytes(rawResponse)
	if perr != nil {
		return nil, httperr.New(http.StatusBadRequest, "CREDENTIAL_REJECTED", "The security key could not be verified.")
	}
	cred, verr := wa.CreateCredential(waUser{id: userID}, sess, parsed)
	if verr != nil {
		return nil, httperr.New(http.StatusBadRequest, "CREDENTIAL_REJECTED", "The security key could not be verified.")
	}
	credID := base64.RawURLEncoding.EncodeToString(cred.ID)
	var dup int
	if err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM user_webauthn_credentials WHERE credential_id = ?`, credID).Scan(&dup); err == nil {
		return nil, httperr.New(http.StatusConflict, "CREDENTIAL_EXISTS", "This security key is already registered.")
	}
	existing, err := s.ListWebAuthnCredentials(ctx, userID)
	if err != nil {
		return nil, err
	}
	finalLabel, err := normalizeWebAuthnLabel(label, fmt.Sprintf("Security key %d", len(existing)+1))
	if err != nil {
		return nil, err
	}
	devType := "singleDevice"
	if cred.Flags.BackupEligible {
		devType = "multiDevice"
	}
	backedUp := 0
	if cred.Flags.BackupState {
		backedUp = 1
	}
	trans := make([]string, 0, len(cred.Transport))
	for _, t := range cred.Transport {
		trans = append(trans, string(t))
	}
	transB, _ := json.Marshal(trans)
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO user_webauthn_credentials
		(id, user_id, credential_id, public_key, counter, rp_id, transports, device_type, backed_up, label)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		uuid.NewString(), userID, credID, base64.RawURLEncoding.EncodeToString(cred.PublicKey),
		int64(cred.Authenticator.SignCount), rp.RPID, string(transB), devType, backedUp, finalLabel); err != nil {
		return nil, err
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: "security_key_registered"})
	return s.ListWebAuthnCredentials(ctx, userID)
}

func (s *Service) BeginWebAuthnAuthentication(ctx context.Context, account string, rp RelyingParty) (string, any, error) {
	var count int
	if err := s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM user_webauthn_credentials WHERE rp_id = ?`, rp.RPID).Scan(&count); err != nil {
		return "", nil, err
	}
	if count == 0 {
		return "", nil, httperr.New(http.StatusConflict, "NO_CREDENTIALS_REGISTERED", "No security keys are registered for this server yet. Add one under Settings first.")
	}
	var allow []protocol.CredentialDescriptor
	if norm := strings.TrimSpace(account); norm != "" {
		var uid string
		if err := s.DB.R.QueryRowContext(ctx, `SELECT id FROM users WHERE username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`, norm, norm).Scan(&uid); err == nil {
			allow, _, _ = s.descriptorsForRP(ctx, uid, rp.RPID)
		}
	}
	wa, err := newWebAuthnClient(rp)
	if err != nil {
		return "", nil, err
	}
	var opts []webauthn.LoginOption
	if len(allow) > 0 {
		opts = append(opts, webauthn.WithAllowedCredentials(allow))
	}
	opts = append(opts, webauthn.WithUserVerification(protocol.VerificationPreferred))
	assertion, sess, err := wa.BeginDiscoverableLogin(opts...)
	if err != nil {
		return "", nil, err
	}
	sessBytes, _ := json.Marshal(sess)
	cid, err := s.storeChallenge(ctx, "authentication", "", string(sessBytes), rp)
	if err != nil {
		return "", nil, err
	}
	return cid, assertion.Response, nil
}

func (s *Service) CompleteWebAuthnAuthentication(ctx context.Context, challengeID string, rawResponse json.RawMessage, twoFactorCode string, rp RelyingParty, rc RequestContext) (User, SessionToken, error) {
	_, sessJSON, err := s.consumeChallenge(ctx, challengeID, "authentication", rp)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	var sess webauthn.SessionData
	if err := json.Unmarshal([]byte(sessJSON), &sess); err != nil {
		return User{}, SessionToken{}, httperr.New(http.StatusBadRequest, "CHALLENGE_EXPIRED", "The security key request expired. Please try again.")
	}
	parsed, perr := protocol.ParseCredentialRequestResponseBytes(rawResponse)
	if perr != nil {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "security_key_login_failed", IPAddress: rc.IPAddress})
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "UNKNOWN_CREDENTIAL", "This security key is not registered.")
	}
	credID := parsed.ID
	var rowID, userID, pubKey, transJSON string
	var counter uint32
	err = s.DB.R.QueryRowContext(ctx, `SELECT id, user_id, public_key, counter, transports
		FROM user_webauthn_credentials WHERE credential_id = ? AND rp_id = ?`, credID, rp.RPID).
		Scan(&rowID, &userID, &pubKey, &counter, &transJSON)
	if err != nil {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "security_key_login_failed", IPAddress: rc.IPAddress})
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "UNKNOWN_CREDENTIAL", "This security key is not registered.")
	}
	rawPub, _ := base64.RawURLEncoding.DecodeString(pubKey)
	var tList []string
	_ = json.Unmarshal([]byte(transJSON), &tList)
	var pt []protocol.AuthenticatorTransport
	for _, t := range tList {
		pt = append(pt, protocol.AuthenticatorTransport(t))
	}
	wa, err := newWebAuthnClient(rp)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	cred, verr := wa.ValidateDiscoverableLogin(func(rawID, userHandle []byte) (webauthn.User, error) {
		if len(userHandle) > 0 && string(userHandle) != userID {
			return nil, errors.New("userHandle mismatch")
		}
		return waUser{
			id: userID,
			credentials: []webauthn.Credential{{
				ID:            rawID,
				PublicKey:     rawPub,
				Transport:     pt,
				Authenticator: webauthn.Authenticator{SignCount: counter},
			}},
		}, nil
	}, sess, parsed)
	if verr != nil {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "security_key_login_failed", IPAddress: rc.IPAddress})
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "CREDENTIAL_REJECTED", "The security key could not be verified.")
	}

	var username, role, createdAt string
	var email, disabledAt sql.NullString
	err = s.DB.R.QueryRowContext(ctx, `SELECT username, email, role, disabled_at, created_at FROM users WHERE id = ?`, userID).
		Scan(&username, &email, &role, &disabledAt, &createdAt)
	if err != nil {
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "UNKNOWN_CREDENTIAL", "This security key is not registered.")
	}
	if disabledAt.Valid && disabledAt.String != "" {
		return User{}, SessionToken{}, httperr.New(http.StatusForbidden, "ACCOUNT_DISABLED", "This account is disabled.")
	}
	if !parsed.Response.AuthenticatorData.Flags.UserVerified() {
		if err := s.VerifySecondFactor(ctx, userID, twoFactorCode); err != nil {
			return User{}, SessionToken{}, err
		}
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE user_webauthn_credentials SET counter = ?, last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`,
		int64(cred.Authenticator.SignCount), rowID)
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, userID)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: "security_key_login_succeeded", IPAddress: rc.IPAddress})

	u := User{ID: userID, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt}
	tok, err := s.CreateSession(ctx, userID, rc)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	return u, tok, nil
}

func (s *Service) RenameWebAuthnCredential(ctx context.Context, userID, credID, label string) ([]WebAuthnCredentialView, error) {
	next, err := normalizeWebAuthnLabel(label, "")
	if err != nil {
		return nil, err
	}
	if next == "" {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_LABEL", "A security key name is required.")
	}
	res, err := s.DB.W.ExecContext(ctx, `UPDATE user_webauthn_credentials SET label = ? WHERE id = ? AND user_id = ?`, next, credID, userID)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, httperr.New(http.StatusNotFound, "CREDENTIAL_NOT_FOUND", "This security key does not exist.")
	}
	return s.ListWebAuthnCredentials(ctx, userID)
}

func (s *Service) DeleteWebAuthnCredential(ctx context.Context, userID, credID string) ([]WebAuthnCredentialView, error) {
	res, err := s.DB.W.ExecContext(ctx, `DELETE FROM user_webauthn_credentials WHERE id = ? AND user_id = ?`, credID, userID)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, httperr.New(http.StatusNotFound, "CREDENTIAL_NOT_FOUND", "This security key does not exist.")
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: "security_key_removed"})
	return s.ListWebAuthnCredentials(ctx, userID)
}
