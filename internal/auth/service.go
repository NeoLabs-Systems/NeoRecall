package auth

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/account"
	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/pwpolicy"
	"github.com/NeoLabs-Systems/neolabs-go/qrlogin"
	"github.com/NeoLabs-Systems/neolabs-go/servicemail"
	"github.com/NeoLabs-Systems/neolabs-go/sessionx"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
	"github.com/NeoLabs-Systems/neolabs-go/userid"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

// User is the public account projection returned by /auth endpoints.
type User struct {
	ID        string  `json:"id"`
	Username  string  `json:"username"`
	Email     *string `json:"email"`
	Role      string  `json:"role"`
	CreatedAt string  `json:"createdAt"`
}

// SessionToken is returned on login/registration/webauthn sign-in.
type SessionToken struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expiresAt"`
}

// RequestContext carries client metadata for sessions and audit rows.
type RequestContext struct {
	IPAddress string
	UserAgent string
}

// EraseResult reports unlinked file count on content erasure.
type EraseResult struct {
	Files int `json:"files"`
}

// Service owns user accounts, sessions, 2FA, recovery codes, API keys, and WebAuthn.
type Service struct {
	DB          *dbx.DB
	Cfg         func() config.Config
	MasterKey   func() ([]byte, error)
	RemoveIndex func(ctx context.Context, tx *sql.Tx, userID string) error
	QR          *qrlogin.Store
	Mailer      servicemail.Mailer

	resetTries servicemail.AttemptLimiter
	storeMu    sync.Mutex
	store      *sessionx.Store
}

// NewService wires the shared sign-in packages to NeoRecall's database.
func NewService(db *dbx.DB, cfg func() config.Config, masterKey func() ([]byte, error)) *Service {
	return &Service{
		DB: db, Cfg: cfg, MasterKey: masterKey,
		QR:     &qrlogin.Store{DB: db},
		Mailer: servicemail.Sender{Cfg: cfg().Mail},
	}
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func nullableStr(v string) sql.NullString {
	if strings.TrimSpace(v) == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: v, Valid: true}
}

func nullPtr(v sql.NullString) *string {
	if !v.Valid {
		return nil
	}
	cp := v.String
	return &cp
}

// sessions is the shared session store; the apps' tokens are bearer sessions.
func (s *Service) sessions(ctx context.Context) (*sessionx.Store, error) {
	s.storeMu.Lock()
	defer s.storeMu.Unlock()
	if s.store == nil {
		store, err := sessionx.NewStore(ctx, s.DB.W)
		if err != nil {
			return nil, err
		}
		s.store = store
	}
	return s.store, nil
}

// CreateSession issues an nrs_ bearer session.
func (s *Service) CreateSession(ctx context.Context, userID string, rc RequestContext) (SessionToken, error) {
	store, err := s.sessions(ctx)
	if err != nil {
		return SessionToken{}, err
	}
	ttlMs := s.cfg().SessionTTLMs
	if ttlMs <= 0 {
		ttlMs = 30 * 24 * 60 * 60 * 1000
	}
	if err := store.ClearExpired(ctx); err != nil {
		return SessionToken{}, err
	}
	token, expires, err := store.IssueBearer(ctx, "nrs_", map[string]any{
		"userId": userID, "ipAddress": rc.IPAddress, "userAgent": rc.UserAgent, "createdAt": time.Now().UTC().Format(time.RFC3339),
	}, time.Duration(ttlMs)*time.Millisecond)
	if err != nil {
		return SessionToken{}, err
	}
	return SessionToken{Token: token, ExpiresAt: timeutil.FormatISO(expires)}, nil
}

// Register creates a user account (first user becomes admin unless NEORECALL_ADMIN_USERS reserves the name).
func (s *Service) Register(ctx context.Context, username string, email *string, password string, rc RequestContext) (User, SessionToken, error) {
	c := s.cfg()
	if !c.RegistrationEnabled {
		return User{}, SessionToken{}, httperr.New(http.StatusForbidden, "REGISTRATION_DISABLED", "Registration is disabled.")
	}
	normUser := strings.TrimSpace(username)
	if len(normUser) < 3 || len(normUser) > 64 {
		return User{}, SessionToken{}, httperr.New(http.StatusBadRequest, "INVALID_USERNAME", "Username must contain 3 to 64 characters.")
	}
	var emailText string
	if email != nil {
		emailText = strings.TrimSpace(*email)
	}
	if err := ValidateNewPassword(password, normUser, emailText); err != nil {
		return User{}, SessionToken{}, err
	}
	var normEmail *string
	if email != nil && strings.TrimSpace(*email) != "" {
		e := strings.ToLower(strings.TrimSpace(*email))
		normEmail = &e
	}

	var exists int
	err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM users WHERE username = ? COLLATE NOCASE`, normUser).Scan(&exists)
	if err == nil {
		return User{}, SessionToken{}, httperr.New(http.StatusConflict, "USERNAME_TAKEN", "This username is already in use.")
	} else if !errors.Is(err, sql.ErrNoRows) {
		return User{}, SessionToken{}, err
	}

	if s.IsReservedAdminUsername(ctx, normUser) {
		return User{}, SessionToken{}, httperr.New(http.StatusConflict, "USERNAME_RESERVED",
			"This username is reserved by the server configuration (NEORECALL_ADMIN_USERS). Choose another one, or remove it from that list to register it.")
	}
	if normEmail != nil {
		err = s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM users WHERE email = ? COLLATE NOCASE`, *normEmail).Scan(&exists)
		if err == nil {
			return User{}, SessionToken{}, httperr.New(http.StatusConflict, "EMAIL_TAKEN", "This email is already in use.")
		} else if !errors.Is(err, sql.ErrNoRows) {
			return User{}, SessionToken{}, err
		}
	}

	pwHash, err := crypto.HashPassword(password)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	id := uuid.NewString()

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	defer tx.Rollback()

	role := "admin"
	var dummy int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM users LIMIT 1`).Scan(&dummy); err == nil {
		role = "user"
	} else if !errors.Is(err, sql.ErrNoRows) {
		return User{}, SessionToken{}, err
	}

	var emailArg sql.NullString
	if normEmail != nil {
		emailArg = sql.NullString{String: *normEmail, Valid: true}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, ?, ?, ?, ?)`,
		id, normUser, emailArg, pwHash, role); err != nil {
		return User{}, SessionToken{}, err
	}
	if err := audit.RecordExec(ctx, tx, audit.Entry{
		ActorType:      "user",
		ActorID:        id,
		AffectedUserID: id,
		Action:         "user_registered",
		IPAddress:      rc.IPAddress,
	}); err != nil {
		return User{}, SessionToken{}, err
	}
	if err := tx.Commit(); err != nil {
		return User{}, SessionToken{}, err
	}

	user, err := s.FindUserByID(ctx, id)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	sess, err := s.CreateSession(ctx, id, rc)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	return *user, sess, nil
}

func (s *Service) FindUserByID(ctx context.Context, id string) (*User, error) {
	var u User
	var email sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, email, role, created_at FROM users WHERE id = ?`, id).
		Scan(&u.ID, &u.Username, &email, &u.Role, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.Email = nullPtr(email)
	return &u, nil
}

func normalizeTwoFactorCode(v string) string {
	v = strings.ReplaceAll(strings.TrimSpace(v), " ", "")
	v = strings.ReplaceAll(v, "-", "")
	return v
}

func recoveryCodeHash(v string) string {
	return crypto.SHA256Hex(strings.ToUpper(normalizeTwoFactorCode(v)))
}

// consumeRecoveryCode spends an unused recovery code in one write, so a code
// works once even when two requests race.
func (s *Service) consumeRecoveryCode(ctx context.Context, userID, code string) (bool, error) {
	if code == "" {
		return false, nil
	}
	res, err := s.DB.W.ExecContext(ctx, `UPDATE user_recovery_codes SET used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE id = (SELECT id FROM user_recovery_codes WHERE user_id = ? AND used_at IS NULL AND code_hash IN (?, ?) LIMIT 1)`,
		userID, recoveryCodeHash(code), crypto.SHA256Hex(strings.ToUpper(code)))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// ValidateNewPassword applies the NeoLabs password policy.
func ValidateNewPassword(password, username, email string) error {
	strength := pwpolicy.Evaluate(password, pwpolicy.Context{Username: username, Email: email})
	if !strength.IsAcceptable {
		return httperr.New(http.StatusBadRequest, "WEAK_PASSWORD", pwpolicy.Error(strength))
	}
	return nil
}

// VerifySecondFactor checks the sign-in's 2FA code when 2FA is on, under
// the per-account confirmation lockout.
func (s *Service) VerifySecondFactor(ctx context.Context, userID, rawCode string) error {
	f, err := verifier{s}.Factors(ctx, userid.ID(userID))
	if err != nil || !f.TwoFactor {
		return err
	}
	if normalizeTwoFactorCode(rawCode) == "" {
		he := httperr.New(http.StatusUnauthorized, "TWO_FACTOR_REQUIRED", "A two-factor authentication code is required.")
		he.Extra = map[string]any{"userId": userID}
		return he
	}
	codeOnly := only{verifier{s}, account.Factors{TwoFactor: true}}
	return httpError(s.reauth(codeOnly).Confirm(ctx, userid.ID(userID), "", rawCode, false))
}

// AuthenticateCredentials verifies username/email + password + optional TOTP/recovery code.
func (s *Service) AuthenticateCredentials(ctx context.Context, account, password, twoFactorCode string, rc RequestContext) (*User, error) {
	acct := strings.TrimSpace(account)
	var id, username, pwHash, role, createdAt string
	var email, disabledAt sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, email, password_hash, role, disabled_at, created_at
		FROM users WHERE username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`, acct, acct).
		Scan(&id, &username, &email, &pwHash, &role, &disabledAt, &createdAt)
	valid := err == nil && crypto.VerifyPassword(password, pwHash)
	if !valid {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "login_failed", IPAddress: rc.IPAddress})
		return nil, httperr.New(http.StatusUnauthorized, "INVALID_CREDENTIALS", "Username or password is incorrect.")
	}
	if disabledAt.Valid && disabledAt.String != "" {
		return nil, httperr.New(http.StatusForbidden, "ACCOUNT_DISABLED", "This account is disabled.")
	}
	if err := s.VerifySecondFactor(ctx, id, twoFactorCode); err != nil {
		return nil, err
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, id)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: id, AffectedUserID: id, Action: "login_succeeded", IPAddress: rc.IPAddress})
	return &User{ID: id, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt}, nil
}

// CompleteTwoFactor finishes login when a user has already proved their first factor (e.g. OAuth sign-in step).
func (s *Service) CompleteTwoFactor(ctx context.Context, userID, twoFactorCode string, rc RequestContext) (*User, error) {
	var id, username, role, createdAt string
	var email, disabledAt sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, email, role, disabled_at, created_at FROM users WHERE id = ?`, userID).
		Scan(&id, &username, &email, &role, &disabledAt, &createdAt)
	if err != nil {
		_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "system", Action: "login_failed", IPAddress: rc.IPAddress})
		return nil, httperr.New(http.StatusUnauthorized, "INVALID_CREDENTIALS", "Username or password is incorrect.")
	}
	if disabledAt.Valid && disabledAt.String != "" {
		return nil, httperr.New(http.StatusForbidden, "ACCOUNT_DISABLED", "This account is disabled.")
	}
	if err := s.VerifySecondFactor(ctx, id, twoFactorCode); err != nil {
		return nil, err
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, id)
	_ = audit.Record(ctx, s.DB, audit.Entry{ActorType: "user", ActorID: id, AffectedUserID: id, Action: "login_succeeded", IPAddress: rc.IPAddress})
	return &User{ID: id, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt}, nil
}

func (s *Service) Login(ctx context.Context, account, password, twoFactorCode string, rc RequestContext) (User, SessionToken, error) {
	u, err := s.AuthenticateCredentials(ctx, account, password, twoFactorCode, rc)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	sess, err := s.CreateSession(ctx, u.ID, rc)
	if err != nil {
		return User{}, SessionToken{}, err
	}
	return *u, sess, nil
}

// AuthenticateSessionToken resolves an nrs_ session token, reading user role live from DB.
func (s *Service) AuthenticateSessionToken(ctx context.Context, token string) *AuthContext {
	if !strings.HasPrefix(token, "nrs_") {
		return nil
	}
	store, err := s.sessions(ctx)
	if err != nil {
		return nil
	}
	sessionID, data, err := store.Bearer(ctx, token)
	userID, _ := data["userId"].(string)
	if err != nil || userID == "" {
		return nil
	}
	var username, role, createdAt string
	var email, disabledAt sql.NullString
	err = s.DB.R.QueryRowContext(ctx, `SELECT username, email, role, disabled_at, created_at FROM users WHERE id = ?`, userID).
		Scan(&username, &email, &role, &disabledAt, &createdAt)
	if err != nil || (disabledAt.Valid && disabledAt.String != "") {
		return nil
	}
	u := User{ID: userID, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt}
	return &AuthContext{
		Type:      "session",
		SessionID: sessionID,
		UserID:    userID,
		Scopes:    []string{"*"},
		User:      u,
	}
}

func (s *Service) Logout(ctx context.Context, sessionID string) error {
	store, err := s.sessions(ctx)
	if err != nil {
		return err
	}
	return store.Destroy(ctx, sessionID)
}

func (s *Service) LogoutAll(ctx context.Context, userID string) error {
	store, err := s.sessions(ctx)
	if err != nil {
		return err
	}
	return store.DestroyForUser(ctx, userID)
}

func (s *Service) ChangePassword(ctx context.Context, userID, currentPassword, newPassword string) error {
	passwordOnly := only{verifier{s}, account.Factors{Password: true}}
	if err := s.reauth(passwordOnly).Confirm(ctx, userid.ID(userID), currentPassword, "", false); err != nil {
		return httpError(err)
	}
	return s.SetPassword(ctx, userID, newPassword)
}

// SetPassword stores a new password that satisfies the policy and signs the
// account out everywhere.
func (s *Service) SetPassword(ctx context.Context, userID, newPassword string) error {
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := s.setPasswordTx(ctx, tx, userID, newPassword); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.LogoutAll(ctx, userID)
}

// setPasswordTx checks a new password against the policy and stores its hash
// in tx.
func (s *Service) setPasswordTx(ctx context.Context, tx *sql.Tx, userID, newPassword string) error {
	var username string
	var email sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT username, email FROM users WHERE id = ?`, userID).Scan(&username, &email)
	if errors.Is(err, sql.ErrNoRows) {
		return httperr.New(http.StatusNotFound, "USER_NOT_FOUND", "This account does not exist.")
	}
	if err != nil {
		return err
	}
	if err := ValidateNewPassword(newPassword, username, email.String); err != nil {
		return err
	}
	hash, err := crypto.HashPassword(newPassword)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE users SET password_hash = ? WHERE id = ?`, hash, userID)
	return err
}

type TwoFactorStatus struct {
	Enabled                bool    `json:"enabled"`
	Pending                bool    `json:"pending"`
	EnabledAt              *string `json:"enabledAt"`
	RecoveryCodesRemaining int     `json:"recoveryCodesRemaining"`
}

func (s *Service) GetTwoFactorStatus(ctx context.Context, userID string) (TwoFactorStatus, error) {
	var pending int
	var enabledAt sql.NullString
	var st TwoFactorStatus
	err := s.DB.R.QueryRowContext(ctx, `SELECT pending, enabled_at FROM user_two_factor WHERE user_id = ?`, userID).Scan(&pending, &enabledAt)
	if err == nil {
		st.Enabled = pending == 0
		st.Pending = pending == 1
		st.EnabledAt = nullPtr(enabledAt)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return st, err
	}
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM user_recovery_codes WHERE user_id = ? AND used_at IS NULL`, userID).
		Scan(&st.RecoveryCodesRemaining)
	return st, nil
}

type TwoFactorSetup struct {
	Secret     string `json:"secret"`
	ManualKey  string `json:"manualKey"`
	OtpauthURI string `json:"otpauthUri"`
}

// BeginTwoFactor starts setting up an authenticator. Setting it up again
// while 2FA is on replaces the working secret and leaves 2FA off until the new
// one is confirmed, so it asks for the password and a current code first, just
// as turning 2FA off does.
func (s *Service) BeginTwoFactor(ctx context.Context, userID, username, password, code string) (TwoFactorSetup, error) {
	var enabled bool
	err := s.DB.R.QueryRowContext(ctx, `SELECT pending = 0 FROM user_two_factor WHERE user_id = ?`, userID).Scan(&enabled)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return TwoFactorSetup{}, err
	}
	if enabled {
		if password == "" || normalizeTwoFactorCode(code) == "" {
			return TwoFactorSetup{}, httperr.New(http.StatusConflict, "TWO_FACTOR_ALREADY_ENABLED",
				"Two-factor authentication is already on. Confirm your password and a current code to set it up again.")
		}
		if err := s.Confirm(ctx, userID, password, code); err != nil {
			return TwoFactorSetup{}, err
		}
	}
	secret, err := totp.GenerateSecret()
	if err != nil {
		return TwoFactorSetup{}, err
	}
	key, err := s.MasterKey()
	if err != nil {
		return TwoFactorSetup{}, err
	}
	enc, err := crypto.EncryptString(key, secret)
	if err != nil {
		return TwoFactorSetup{}, err
	}
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO user_two_factor (user_id, secret_encrypted, pending)
		VALUES (?, ?, 1) ON CONFLICT(user_id) DO UPDATE SET secret_encrypted=excluded.secret_encrypted,
		pending=1, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		userID, enc)
	if err != nil {
		return TwoFactorSetup{}, err
	}
	uri := totp.URI("NeoRecall", username, secret)
	return TwoFactorSetup{Secret: secret, ManualKey: secret, OtpauthURI: uri}, nil
}

func generateRecoveryCodes(n int) ([]string, error) {
	if n <= 0 {
		n = 10
	}
	out := make([]string, n)
	for i := range out {
		code, err := totp.NewRecoveryCode()
		if err != nil {
			return nil, err
		}
		out[i] = code
	}
	return out, nil
}

func (s *Service) ActivateTwoFactor(ctx context.Context, userID, code string) ([]string, error) {
	var secretEnc string
	err := s.DB.R.QueryRowContext(ctx, `SELECT secret_encrypted FROM user_two_factor WHERE user_id = ? AND pending = 1`, userID).Scan(&secretEnc)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_TWO_FACTOR", "The two-factor authentication code is invalid.")
	} else if err != nil {
		return nil, err
	}
	key, err := s.MasterKey()
	if err != nil {
		return nil, err
	}
	secret, err := crypto.DecryptString(key, secretEnc)
	step, ok := totp.MatchStep(secret, code, time.Now())
	if err != nil || !ok {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_TWO_FACTOR", "The two-factor authentication code is invalid.")
	}
	codes, err := generateRecoveryCodes(s.cfg().TwoFactorRecoveryCodeCount)
	if err != nil {
		return nil, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE user_two_factor SET pending=0, last_totp_step=?, enabled_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=?`, step, userID); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM user_recovery_codes WHERE user_id = ?`, userID); err != nil {
		return nil, err
	}
	for _, rc := range codes {
		if _, err := tx.ExecContext(ctx, `INSERT INTO user_recovery_codes (id, user_id, code_hash) VALUES (?, ?, ?)`, uuid.NewString(), userID, recoveryCodeHash(rc)); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return codes, nil
}

func (s *Service) DisableTwoFactor(ctx context.Context, userID, password, code string) error {
	if err := s.Confirm(ctx, userID, password, code); err != nil {
		return err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, _ = tx.ExecContext(ctx, `DELETE FROM user_two_factor WHERE user_id = ?`, userID)
	_, _ = tx.ExecContext(ctx, `DELETE FROM user_recovery_codes WHERE user_id = ?`, userID)
	return tx.Commit()
}

func (s *Service) RegenerateRecoveryCodes(ctx context.Context, userID, password, code string) ([]string, error) {
	if err := s.Confirm(ctx, userID, password, code); err != nil {
		return nil, err
	}
	codes, err := generateRecoveryCodes(s.cfg().TwoFactorRecoveryCodeCount)
	if err != nil {
		return nil, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	_, _ = tx.ExecContext(ctx, `DELETE FROM user_recovery_codes WHERE user_id = ?`, userID)
	for _, rc := range codes {
		if _, err := tx.ExecContext(ctx, `INSERT INTO user_recovery_codes (id, user_id, code_hash) VALUES (?, ?, ?)`, uuid.NewString(), userID, recoveryCodeHash(rc)); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return codes, nil
}

var contentTables = []string{
	"recording_sessions",
	"imports",
	"recording_context_items",
	"consolidation_runs",
	"memories",
	"conversations",
	"voiceprints",
	"speaker_clusters",
	"entities",
	"daily_summaries",
	"search_documents",
	"ai_requests",
	"jobs",
	"event_outbox",
	"processing_metrics",
	"ask_quota_events",
	"transcription_usage",
	"diagnostic_request_events",
	"cloud_archive_items",
	"cloud_recording_assemblies",
}

// storedFilePaths lists the account's temporary and pending files.
func storedFilePaths(ctx context.Context, q account.RowsQuerier, userID string) ([]string, error) {
	queries := []string{
		`SELECT temporary_path FROM audio_chunks WHERE user_id=? AND temporary_path IS NOT NULL`,
		`SELECT temporary_path FROM imports WHERE user_id=? AND temporary_path IS NOT NULL`,
		`SELECT p.temporary_path FROM import_parts p JOIN imports i ON i.id=p.import_id WHERE i.user_id=?`,
		`SELECT original_path FROM recording_context_items WHERE user_id=? AND original_path IS NOT NULL`,
		`SELECT local_path FROM cloud_archive_items WHERE user_id=? AND local_path IS NOT NULL`,
		`SELECT local_dir FROM cloud_recording_assemblies WHERE user_id=?`,
	}
	var out []string
	for _, query := range queries {
		rows, err := q.QueryContext(ctx, query, userID)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var p sql.NullString
			if err := rows.Scan(&p); err != nil {
				rows.Close()
				return nil, err
			}
			if p.Valid && p.String != "" {
				out = append(out, p.String)
			}
		}
		rows.Close()
	}
	return out, nil
}

// EraseContent unlinks all user audio/media files BEFORE wiping all user content rows.
func (s *Service) EraseContent(ctx context.Context, userID, password, code string, unlinkStrict func(string) error) (EraseResult, error) {
	if err := s.Confirm(ctx, userID, password, code); err != nil {
		return EraseResult{}, err
	}
	paths, err := storedFilePaths(ctx, s.DB.R, userID)
	if err != nil {
		return EraseResult{}, err
	}
	for _, p := range paths {
		if unlinkStrict != nil {
			if err := unlinkStrict(p); err != nil {
				return EraseResult{}, err
			}
		}
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return EraseResult{}, err
	}
	defer tx.Rollback()
	if s.RemoveIndex != nil {
		if err := s.RemoveIndex(ctx, tx, userID); err != nil {
			return EraseResult{}, err
		}
	}
	for _, table := range contentTables {
		if _, err := tx.ExecContext(ctx, `DELETE FROM `+table+` WHERE user_id=?`, userID); err != nil {
			return EraseResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return EraseResult{}, err
	}
	return EraseResult{Files: len(paths)}, nil
}
