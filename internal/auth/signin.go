package auth

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/passhash"
	"github.com/NeoLabs-Systems/neolabs-go/qrlogin"
	"github.com/NeoLabs-Systems/neolabs-go/servicemail"
	"github.com/NeoLabs-Systems/neolabs-go/userid"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

const tokenPasswordReset = "password_reset"

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

func (s *Service) mailTokens() servicemail.Tokens { return servicemail.Tokens{DB: s.DB.W} }

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

// PasswordResetAvailable reports whether reset emails can be sent at all.
func (s *Service) PasswordResetAvailable() bool {
	c := s.cfg()
	if !c.Mail.Enabled {
		return false
	}
	_, err := MailLinkBase(c)
	return err == nil
}

// RequestPasswordReset emails a reset link to the account's address. It says
// nothing about whether the account exists, so failures are only returned for
// the caller to log. Without a configured public URL nothing is sent.
func (s *Service) RequestPasswordReset(ctx context.Context, account string) error {
	c := s.cfg()
	mail := c.Mail
	account = strings.TrimSpace(account)
	if !mail.Enabled || account == "" {
		return nil
	}
	base, err := MailLinkBase(c)
	if err != nil {
		return err
	}
	identity, ok, err := webauthnAccounts{s}.ForSignIn(ctx, account)
	if err != nil || !ok || identity.Email == "" {
		return err
	}
	ttl := time.Duration(mail.TokenTTLHours * float64(time.Hour))
	token, _, err := s.mailTokens().Create(ctx, userid.ID(identity.ID), tokenPasswordReset, identity.Email, ttl)
	if err != nil {
		return err
	}
	return s.Mailer.Send(ctx, identity.Email, servicemail.Message{
		Subject: "Reset your NeoRecall password", Title: "Reset your password",
		Intro:     "Use this link to set a new password for " + identity.Username + ". Ignore this email if you did not request a reset.",
		ActionURL: base + passwordResetPath + "?token=" + url.QueryEscape(token), ActionLabel: "Reset password",
		Details: []servicemail.Detail{{Label: "Account", Value: identity.Username}},
	})
}

func invalidResetLink() error {
	return httperr.New(http.StatusBadRequest, "INVALID_RESET_LINK", "Password reset link is invalid or expired.")
}

// ResetPassword spends a reset link on a new password.
func (s *Service) ResetPassword(ctx context.Context, token, password string) error {
	key := passhash.DigestToken(token)
	if err := s.resetTries.Allowed(key); err != nil {
		return httperr.New(http.StatusTooManyRequests, "RATE_LIMITED", err.Error())
	}
	row, err := s.mailTokens().Find(ctx, s.DB.W, token, tokenPasswordReset)
	if err != nil {
		return err
	}
	if row == nil {
		s.resetTries.Register(key)
		return invalidResetLink()
	}
	// Check the policy before spending the link, so a weak password can be retried.
	if err := ValidateNewPassword(password, row.Username, row.CurrentEmail.String); err != nil {
		return err
	}
	res, err := s.DB.W.ExecContext(ctx, `UPDATE user_email_tokens SET consumed_at = datetime('now') WHERE id = ? AND consumed_at IS NULL`, row.ID)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n == 0 {
		return invalidResetLink()
	}
	if err := s.SetPassword(ctx, string(row.UserID), password); err != nil {
		return err
	}
	s.resetTries.Reset(key)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: string(row.UserID), AffectedUserID: string(row.UserID), Action: "password_reset"})
	return nil
}
