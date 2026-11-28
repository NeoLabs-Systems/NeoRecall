package auth

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/account"
	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/lockout"
	"github.com/NeoLabs-Systems/neolabs-go/passhash"
	"github.com/NeoLabs-Systems/neolabs-go/servicemail"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
	"github.com/NeoLabs-Systems/neolabs-go/userid"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

// NeoRecall's side of the shared account lifecycle (neolabs-go/account):
// where accounts, secrets and sessions live, what deleting one erases, and how
// refusals read in NeoRecall's error envelope.

const (
	emailConfirmPath = "/api/v1/auth/email/confirm"
	// forgotMinimumLatency hides whether a reset email was actually sent.
	forgotMinimumLatency = 600 * time.Millisecond
)

// Directory finds NeoRecall accounts for the shared flows.
type Directory struct{ DB *dbx.DB }

func (d Directory) find(ctx context.Context, where string, args ...any) (account.Account, error) {
	var a account.Account
	var id, role string
	var email, verified, disabled sql.NullString
	err := d.DB.R.QueryRowContext(ctx, `SELECT id, username, email, email_verified_at, role, disabled_at FROM users WHERE `+where, args...).
		Scan(&id, &a.Username, &email, &verified, &role, &disabled)
	if errors.Is(err, sql.ErrNoRows) {
		return a, account.ErrNotFound
	}
	if err != nil {
		return a, err
	}
	a.ID, a.Email, a.EmailVerified = userid.ID(id), email.String, verified.String != ""
	a.Disabled = disabled.String != ""
	a.Admin = role == "admin" && !a.Disabled
	return a, nil
}

// Account implements account.Directory.
func (d Directory) Account(ctx context.Context, id userid.ID) (account.Account, error) {
	return d.find(ctx, `id = ?`, string(id))
}

// Lookup implements account.Directory with the sign-in's rule: username or
// email, without case.
func (d Directory) Lookup(ctx context.Context, login string) (account.Account, error) {
	return d.find(ctx, `username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`, login, login)
}

// verifier checks an account's password and 2FA code without counting tries;
// account.Reauth counts them.
type verifier struct{ s *Service }

func (v verifier) Factors(ctx context.Context, id userid.ID) (account.Factors, error) {
	var on bool
	err := v.s.DB.R.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM user_two_factor WHERE user_id = ? AND pending = 0)`, string(id)).Scan(&on)
	return account.Factors{Password: true, TwoFactor: on}, err
}

func (v verifier) CheckPassword(ctx context.Context, id userid.ID, password string) (bool, error) {
	var hash string
	err := v.s.DB.R.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, string(id)).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil && passhash.Verify(hash, password), err
}

// CheckCode accepts a current TOTP code once, or spends an unused recovery
// code.
func (v verifier) CheckCode(ctx context.Context, id userid.ID, code string) (bool, error) {
	var secretEnc string
	err := v.s.DB.R.QueryRowContext(ctx, `SELECT secret_encrypted FROM user_two_factor WHERE user_id = ? AND pending = 0`, string(id)).Scan(&secretEnc)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	key, err := v.s.MasterKey()
	if err != nil {
		return false, err
	}
	secret, err := crypto.DecryptString(key, secretEnc)
	if err != nil {
		return false, err
	}
	code = normalizeTwoFactorCode(code)
	if step, ok := totp.MatchStep(secret, code, time.Now()); ok {
		// Only a step newer than the last one used counts, in one write, so
		// a code seen once cannot be sent again within its window.
		res, err := v.s.DB.W.ExecContext(ctx, `UPDATE user_two_factor SET last_totp_step = ?
			WHERE user_id = ? AND pending = 0 AND last_totp_step < ?`, step, string(id), step)
		if err != nil {
			return false, err
		}
		n, err := res.RowsAffected()
		return n == 1, err
	}
	return v.s.consumeRecoveryCode(ctx, string(id), code)
}

// only narrows a confirmation to some factors: the password alone to change
// it, the code alone at sign-in after the password was checked.
type only struct {
	verifier
	factors account.Factors
}

func (o only) Factors(context.Context, userid.ID) (account.Factors, error) { return o.factors, nil }

// reauth confirms the password and, when 2FA is on, a code, throttled per
// account.
func (s *Service) reauth(v account.Verifier) account.Reauth {
	if v == nil {
		v = verifier{s}
	}
	return account.Reauth{Lockout: lockout.Store{DB: s.DB.W}, Verifier: v}
}

// Confirm re-authenticates a signed-in account before a sensitive action.
func (s *Service) Confirm(ctx context.Context, userID, password, code string) error {
	return httpError(s.reauth(nil).Confirm(ctx, userid.ID(userID), password, code, false))
}

// bearerSessions lists and ends the account's bearer sessions.
type bearerSessions struct{ s *Service }

func (b bearerSessions) store(ctx context.Context) (account.StoreSessions, error) {
	store, err := b.s.sessions(ctx)
	return account.StoreSessions{Store: store}, err
}

func (b bearerSessions) List(ctx context.Context, user userid.ID, current string) ([]account.Session, error) {
	st, err := b.store(ctx)
	if err != nil {
		return nil, err
	}
	return st.List(ctx, user, current)
}

func (b bearerSessions) Revoke(ctx context.Context, user userid.ID, id, current string) error {
	st, err := b.store(ctx)
	if err != nil {
		return err
	}
	return st.Revoke(ctx, user, id, current)
}

func (b bearerSessions) RevokeAll(ctx context.Context, user userid.ID, keep string) error {
	st, err := b.store(ctx)
	if err != nil {
		return err
	}
	return st.RevokeAll(ctx, user, keep)
}

// DestroyForUser ends every session of the account (account.Revoker).
func (b bearerSessions) DestroyForUser(ctx context.Context, userID string) error {
	return b.s.LogoutAll(ctx, userID)
}

// recovery runs the emailed-link flows with the current configuration. No
// link is mailed while email is off or no public URL is configured.
func (s *Service) recovery() *account.Recovery {
	c := s.cfg()
	r := &account.Recovery{
		DB: s.DB.W, Directory: Directory{s.DB},
		ResetPath: passwordResetPath, ConfirmPath: emailConfirmPath,
		TTL:      time.Duration(c.Mail.TokenTTLHours * float64(time.Hour)),
		Messages: mailMessages,
		SetPassword: func(ctx context.Context, tx *sql.Tx, id userid.ID, password string) error {
			return accountError(s.setPasswordTx(ctx, tx, string(id), password))
		},
		Sessions: bearerSessions{s},
		Changed:  s.recordChange,
		Attempts: &s.resetTries,
	}
	if base, err := MailLinkBase(c); c.Mail.Enabled && err == nil {
		r.Mailer, r.PublicURL = s.Mailer, base
	}
	// Without email an address can still be set, unconfirmed, after
	// re-authenticating; with email it must be confirmed by its link.
	r.RequireChangeConfirmation = r.Enabled()
	return r
}

var mailMessages = account.Messages{
	Reset: func(a account.Account, link string) servicemail.Message {
		return servicemail.Message{
			Subject: "Reset your NeoRecall password", Title: "Reset your password",
			Intro:     "Use this link to set a new password for " + a.Username + ". Ignore this email if you did not request a reset.",
			ActionURL: link, ActionLabel: "Reset password",
			Details: []servicemail.Detail{{Label: "Account", Value: a.Username}},
		}
	},
	Signup: func(a account.Account, link string) servicemail.Message {
		return servicemail.Message{
			Subject: "Confirm your NeoRecall email", Title: "Confirm your email",
			Intro:     "Confirm this address for the NeoRecall account " + a.Username + ".",
			ActionURL: link, ActionLabel: "Confirm email",
			Details: []servicemail.Detail{{Label: "Account", Value: a.Username}},
		}
	},
	Change: func(a account.Account, email, link string) servicemail.Message {
		return servicemail.Message{
			Subject: "Confirm your new NeoRecall email", Title: "Confirm your new email",
			Intro:     "Confirm that " + email + " should become the address of the NeoRecall account " + a.Username + ". Ignore this email if you did not ask for it.",
			ActionURL: link, ActionLabel: "Confirm email",
			Details: []servicemail.Detail{{Label: "Account", Value: a.Username}, {Label: "New email", Value: email}},
		}
	},
	ChangeRequested: func(a account.Account, email string) servicemail.Message {
		return servicemail.Message{
			Subject: "Your NeoRecall email is being changed", Title: "Email change requested",
			Intro:   "Someone signed in to " + a.Username + " asked to move the account to " + email + ". If that was not you, change your password.",
			Details: []servicemail.Detail{{Label: "Account", Value: a.Username}, {Label: "New email", Value: email}},
		}
	},
}

// recordChange writes the audit row of a committed reset or address change.
func (s *Service) recordChange(ctx context.Context, e account.Event) {
	action := map[account.EventKind]string{
		account.PasswordReset:  "password_reset",
		account.EmailConfirmed: "email_confirmed",
		account.EmailChanged:   "email_changed",
	}[e.Kind]
	id := string(e.Account.ID)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: id, AffectedUserID: id, Action: action})
}

// deleter erases an account: its rows in one transaction, then its files
// and sessions. Admin accounts are never deleted; the role is revoked first.
func (s *Service) deleter() *account.Deleter {
	home := s.cfg().Paths.Home
	return &account.Deleter{
		DB: s.DB.W, Rule: account.KeepAdmins,
		Steps: []account.Step{
			func(ctx context.Context, tx *sql.Tx, d *account.Deletion) error {
				paths, err := storedFilePaths(ctx, tx, string(d.Account.ID))
				for _, p := range paths {
					d.RemoveAfterCommit(home, p)
				}
				return err
			},
			func(ctx context.Context, tx *sql.Tx, d *account.Deletion) error {
				id := string(d.Account.ID)
				if s.RemoveIndex != nil {
					if err := s.RemoveIndex(ctx, tx, id); err != nil {
						return err
					}
				}
				// Audit rows keep what happened but lose who it was.
				if _, err := tx.ExecContext(ctx, `UPDATE audit_log SET actor_id=NULL, ip_address=NULL, metadata_json=NULL, resource_id=NULL
					WHERE actor_type IN ('user','admin') AND actor_id=?`, id); err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, `UPDATE audit_log SET ip_address=NULL, metadata_json=NULL WHERE affected_user_id=?`, id); err != nil {
					return err
				}
				if d.Self() {
					return nil
				}
				return audit.RecordExec(ctx, tx, audit.Entry{ActorType: "admin", ActorID: string(d.Actor), Action: "admin.user_deleted", ResourceType: "user"})
			},
			account.DeleteWhere("id", "users"),
		},
		Sessions: bearerSessions{s},
	}
}

// accountError carries NeoRecall's own refusals into the shared flows, which
// show only account errors to the client.
func accountError(err error) error {
	var he *httperr.Error
	if errors.As(err, &he) && he.Status < 500 {
		return &account.Error{Status: he.Status, Code: he.Code, Message: he.Message}
	}
	return err
}

// httpError words a refusal of the shared flows in NeoRecall's codes. Other
// errors pass through to httperr.WriteError.
func httpError(err error) error {
	var e *account.Error
	var locked *lockout.LockedError
	if err == nil || !errors.As(err, &e) && !errors.As(err, &locked) {
		return err
	}
	p := account.Describe(err)
	switch {
	case errors.Is(err, account.ErrWrongPassword):
		p.Code = "INVALID_PASSWORD"
	case errors.Is(err, account.ErrWrongCode):
		p.Code = "INVALID_TWO_FACTOR"
	case errors.Is(err, account.ErrBadRequest):
		p.Code = "VALIDATION_ERROR"
	case errors.Is(err, account.ErrAdminSelfDelete):
		p.Message = "Admin accounts can’t delete themselves. Ask whoever runs this server to revoke admin with `neorecall admin revoke <username>` first."
	}
	he := httperr.New(p.Status, p.Code, p.Message)
	if p.RetryAfter > 0 {
		he.Details = map[string]any{"retryAfter": p.RetryAfter}
	}
	return he
}

func (rt *Routes) writeAccountError(w http.ResponseWriter, r *http.Request, err error) {
	httperr.WriteError(w, r, rt.Log, httpError(err))
}

// accountHandlers are the shared account routes over this request's
// configuration.
func (rt *Routes) accountHandlers() *account.Handlers {
	reauth := rt.Svc.reauth(nil)
	return &account.Handlers{
		Directory: Directory{rt.Svc.DB},
		Identify: func(r *http.Request) (userid.ID, bool) {
			a := FromContext(r.Context())
			if a == nil {
				return "", false
			}
			return userid.ID(a.UserID), true
		},
		CurrentSession: func(r *http.Request) string {
			if a := FromContext(r.Context()); a != nil && a.Type == "session" {
				return a.SessionID
			}
			return ""
		},
		WriteError: rt.writeAccountError,
		Fields:     account.Fields{Password: "password", Code: "twoFactorCode"},
		Log:        rt.Log,
		Reauth:     &reauth,
		Recovery:   rt.Svc.recovery(),
		Pages:      account.AuthPages{Brand: rpName, ResetPath: passwordResetPath, ConfirmPath: emailConfirmPath},
		MinLatency: forgotMinimumLatency,
		AnonymousMessage: func(*http.Request, string) string {
			return "If that account has an email address, NeoRecall will send a password reset link."
		},
		Exporter: rt.Exporter,
		Deleter:  rt.Svc.deleter(),
		Sessions: bearerSessions{rt.Svc},
	}
}

// shared serves a request with one of the shared account handlers.
func (rt *Routes) shared(pick func(h *account.Handlers) http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) { pick(rt.accountHandlers()).ServeHTTP(w, r) }
}

// limited runs h within a limiter.
func (rt *Routes) limited(l *httperr.Limiter, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if l.Allow(w, r, rt.Log) {
			h(w, r)
		}
	}
}

func (rt *Routes) mountAccount(mux *http.ServeMux) {
	reqSess := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireSession(h))
	}
	adm := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAdmin(h))
	}

	mux.HandleFunc("POST /api/v1/auth/password/forgot", rt.limited(rt.resetL, rt.handleForgotPassword))
	mux.HandleFunc("GET "+passwordResetPath, rt.shared((*account.Handlers).ResetPage))
	mux.HandleFunc("POST "+passwordResetPath, rt.limited(rt.resetL, rt.shared((*account.Handlers).ResetSubmit)))
	mux.HandleFunc("GET "+emailConfirmPath, rt.shared((*account.Handlers).ConfirmPage))
	mux.HandleFunc("POST "+emailConfirmPath, rt.limited(rt.resetL, rt.shared((*account.Handlers).ConfirmSubmit)))

	mux.Handle("GET /api/v1/auth/email", reqSess(rt.handleEmailState))
	mux.Handle("PUT /api/v1/auth/email", reqSess(rt.shared(func(h *account.Handlers) http.HandlerFunc { return h.ChangeEmail(rt.writeEmailState) })))
	mux.Handle("POST /api/v1/auth/email/resend", reqSess(rt.limited(rt.resetL, rt.shared(func(h *account.Handlers) http.HandlerFunc {
		return h.ResendEmail(rt.writeEmailState)
	}))))

	mux.Handle("POST /api/v1/auth/account/export", reqSess(rt.limited(rt.exportL, rt.shared(func(h *account.Handlers) http.HandlerFunc {
		return h.Export(true)
	}))))
	mux.Handle("DELETE /api/v1/auth/account", reqSess(rt.shared(func(h *account.Handlers) http.HandlerFunc {
		return h.DeleteAccount(account.DeleteOptions{Reauth: true})
	})))
	mux.Handle("DELETE /api/v1/admin/users/{id}", adm(rt.shared(func(h *account.Handlers) http.HandlerFunc {
		return h.AdminDeleteAccount(func(r *http.Request) (userid.ID, error) { return userid.ID(r.PathValue("id")), nil }, nil)
	})))

	mux.Handle("GET /api/v1/auth/sessions", reqSess(rt.shared((*account.Handlers).ListSessions)))
	mux.Handle("DELETE /api/v1/auth/sessions/{id}", reqSess(rt.shared(func(h *account.Handlers) http.HandlerFunc { return h.RevokeSession("id") })))
	mux.Handle("POST /api/v1/auth/logout-all", reqSess(rt.shared(func(h *account.Handlers) http.HandlerFunc {
		return h.SignOutEverywhere(false, nil)
	})))
}

// handleForgotPassword answers the same whether or not a link went out, and
// tells the operator when links cannot be built.
func (rt *Routes) handleForgotPassword(w http.ResponseWriter, r *http.Request) {
	c := rt.Svc.cfg()
	if _, err := MailLinkBase(c); c.Mail.Enabled && err != nil {
		rt.Log.Warn("password reset email not sent: set NEORECALL_PUBLIC_URL so reset links point at this server", "error", err)
	}
	rt.accountHandlers().Forgot().ServeHTTP(w, r)
}

// emailState is the account's address as the settings screen shows it.
func (rt *Routes) emailState(a account.Account, pending string) map[string]any {
	var email any
	if a.Email != "" {
		email = a.Email
	}
	var waiting any
	if pending != "" {
		waiting = pending
	}
	return map[string]any{"email": email, "emailVerified": a.EmailVerified, "pendingEmail": waiting, "canConfirm": rt.Svc.recovery().Enabled()}
}

func (rt *Routes) writeEmailState(w http.ResponseWriter, r *http.Request, a account.Account, pending string) {
	httpx.WriteJSON(w, http.StatusOK, rt.emailState(a, pending))
}

func (rt *Routes) handleEmailState(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	a, err := Directory{rt.Svc.DB}.Account(ctx, userid.ID(FromContext(ctx).UserID))
	var pending string
	if err == nil {
		pending, err = rt.Svc.recovery().PendingEmail(ctx, a.ID)
	}
	if err != nil {
		rt.writeAccountError(w, r, err)
		return
	}
	rt.writeEmailState(w, r, a, pending)
}
