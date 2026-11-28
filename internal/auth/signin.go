package auth

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/passhash"
	"github.com/NeoLabs-Systems/neolabs-go/qrlogin"
	"github.com/NeoLabs-Systems/neolabs-go/userid"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

// signIn issues a session for an account that has proved who it is.
func (s *Service) signIn(ctx context.Context, userID, action string, rc RequestContext) (User, SessionToken, error) {
	var disabled bool
	if err := s.DB.R.QueryRowContext(ctx, `SELECT COALESCE(disabled_at, '') != '' FROM users WHERE id = ?`, userID).Scan(&disabled); err != nil {
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "INVALID_CREDENTIALS", "This account is no longer available.")
	}
	if disabled {
		return User{}, SessionToken{}, httperr.New(http.StatusForbidden, "ACCOUNT_DISABLED", "This account is disabled.")
	}
	user, err := s.FindUserByID(ctx, userID)
	if err != nil || user == nil {
		return User{}, SessionToken{}, httperr.New(http.StatusUnauthorized, "INVALID_CREDENTIALS", "This account is no longer available.")
	}
	token, err := s.CreateSession(ctx, userID, rc)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, userID)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: userID, AffectedUserID: userID, Action: action, IPAddress: rc.IPAddress})
	return *user, token, nil
}

// QRChallenge is what the signing-in screen shows and polls with.
type QRChallenge struct {
	ChallengeID string `json:"challengeId"`
	PollToken   string `json:"pollToken"`
	ExpiresAt   string `json:"expiresAt"`
	Status      string `json:"status"`
	QRPayload   string `json:"qrPayload"`
	BackendURL  string `json:"backendUrl"`
}

// CreateQRChallenge starts a sign-in another signed-in device can approve.
func (s *Service) CreateQRChallenge(ctx context.Context, baseURL string, req qrlogin.Request) (QRChallenge, error) {
	c, err := s.QR.Create(ctx, req)
	if err != nil {
		return QRChallenge{}, err
	}
	query := "v=1&backend=" + url.QueryEscape(baseURL) + "&challenge=" + url.QueryEscape(c.ChallengeID) + "&secret=" + url.QueryEscape(c.ApproveSecret)
	return QRChallenge{
		ChallengeID: c.ChallengeID, PollToken: c.PollToken, ExpiresAt: c.ExpiresAt, Status: c.Status,
		QRPayload: "neorecall://qr-login?" + query, BackendURL: baseURL,
	}, nil
}

// ClaimQRLogin turns an approved challenge into a session, once. The approving
// device was signed in, so no second factor is asked again.
func (s *Service) ClaimQRLogin(ctx context.Context, challengeID, pollToken string, rc RequestContext) (User, SessionToken, error) {
	claimed, err := s.QR.Claim(ctx, challengeID, pollToken)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	return s.signIn(ctx, string(claimed.UserID), "qr_login_succeeded", rc)
}

// ApproveQRLogin lets the signed-in account sign the other device in.
func (s *Service) ApproveQRLogin(ctx context.Context, a *AuthContext, challengeID, secret string, metadata any) (*qrlogin.Challenge, error) {
	c, err := s.QR.Approve(ctx, challengeID, secret, userid.ID(a.UserID), passhash.DigestToken(a.SessionID), metadata)
	if err != nil {
		return nil, err
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: a.UserID, AffectedUserID: a.UserID, Action: "qr_login_approved"})
	return c, nil
}

// ErrNoMailLinkBase means no usable public URL is configured, so no emailed
// link can be built.
var ErrNoMailLinkBase = errors.New("no public URL is configured for emailed links; set NEORECALL_PUBLIC_URL")

// MailLinkBase is the address every emailed link points at: the configured
// NEORECALL_EMAIL_PUBLIC_URL, falling back to NEORECALL_PUBLIC_URL. It never
// comes from a request, whose Host header whoever sends it chooses.
func MailLinkBase(c config.Config) (string, error) {
	raw := strings.TrimSpace(c.Mail.PublicURL)
	if raw == "" {
		raw = strings.TrimSpace(c.PublicURL)
	}
	if raw == "" {
		return "", ErrNoMailLinkBase
	}
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("%w (%q is not an absolute http or https URL)", ErrNoMailLinkBase, raw)
	}
	return u.String(), nil
}

// PasswordResetAvailable reports whether reset emails can be sent at all:
// email is on and links have a public URL to point at.
func (s *Service) PasswordResetAvailable() bool { return s.recovery().Enabled() }
