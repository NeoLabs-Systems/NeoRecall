package auth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/passhash"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

const recoveryAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

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

// CreateSession issues an nrs_ bearer session stored as SHA-256 hash.
func (s *Service) CreateSession(ctx context.Context, userID string, rc RequestContext) (SessionToken, error) {
	tokSuffix, err := crypto.RandomToken(32)
	if err != nil {
		return SessionToken{}, err
	}
	token := "nrs_" + tokSuffix
	id := uuid.NewString()
	ttlMs := s.cfg().SessionTTLMs
	if ttlMs <= 0 {
		ttlMs = 30 * 24 * 60 * 60 * 1000
	}
	expiresAt := timeutil.FormatISO(timeutil.AddMillis(time.Now(), ttlMs))
	_, err = s.DB.W.ExecContext(ctx, `INSERT INTO user_sessions
		(id, user_id, token_hash, expires_at, ip_address, user_agent) VALUES (?, ?, ?, ?, ?, ?)`,
		id, userID, crypto.SHA256Hex(token), expiresAt, nullableStr(rc.IPAddress), nullableStr(rc.UserAgent),
	)
	if err != nil {
		return SessionToken{}, err
	}
	return SessionToken{Token: token, ExpiresAt: expiresAt}, nil
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
	if len(password) < 12 {
		return User{}, SessionToken{}, httperr.New(http.StatusBadRequest, "WEAK_PASSWORD", "Password must contain at least 12 characters.")
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

func (s *Service) consumeRecoveryCode(ctx context.Context, userID, code string) bool {
	if code == "" {
		return false
	}
	norm := recoveryCodeHash(code)
	legacy := crypto.SHA256Hex(strings.ToUpper(code))
	var id string
	err := s.DB.R.QueryRowContext(ctx, `SELECT id FROM user_recovery_codes
		WHERE user_id = ? AND used_at IS NULL AND (code_hash = ? OR code_hash = ?)`, userID, norm, legacy).Scan(&id)
	if err != nil {
		return false
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE user_recovery_codes SET used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, id)
	return true
}

// VerifySecondFactor validates a pending 2FA challenge if enabled for userID.
func (s *Service) VerifySecondFactor(ctx context.Context, userID, rawCode string) error {
	var secretEnc string
	var pending, failedAttempts int
	var lockedUntil sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT secret_encrypted, pending, failed_attempts, locked_until
		FROM user_two_factor WHERE user_id = ? AND pending = 0`, userID).
		Scan(&secretEnc, &pending, &failedAttempts, &lockedUntil)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}

	code := normalizeTwoFactorCode(rawCode)
	if code == "" {
		he := httperr.New(http.StatusUnauthorized, "TWO_FACTOR_REQUIRED", "A two-factor authentication code is required.")
		he.Extra = map[string]any{"userId": userID}
		return he
	}
	if lockedUntil.Valid {
		if t, perr := timeutil.ParseISO(lockedUntil.String); perr == nil && t.After(time.Now()) {
			return httperr.New(http.StatusTooManyRequests, "TWO_FACTOR_LOCKED", "Two-factor authentication is temporarily locked.")
		}
	}

	key, err := s.MasterKey()
	if err != nil {
		return err
	}
	secret, err := crypto.DecryptString(key, secretEnc)
	if err != nil {
		return err
	}
	valid := totp.Verify(secret, code, time.Now()) || s.consumeRecoveryCode(ctx, userID, code)
	if valid {
		_, _ = s.DB.W.ExecContext(ctx, `UPDATE user_two_factor SET failed_attempts = 0, locked_until = NULL WHERE user_id = ?`, userID)
		return nil
	}

	c := s.cfg()
	lockAfter := c.TwoFactorLockAfterFailures
	if lockAfter <= 0 {
		lockAfter = 5
	}
	lockMs := c.TwoFactorLockMs
	if lockMs <= 0 {
		lockMs = 5 * 60_000
	}
	attempts := failedAttempts + 1
	var nextLocked sql.NullString
	if attempts >= lockAfter {
		nextLocked = sql.NullString{String: timeutil.FormatISO(timeutil.AddMillis(time.Now(), lockMs)), Valid: true}
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE user_two_factor SET failed_attempts = ?, locked_until = ? WHERE user_id = ?`, attempts, nextLocked, userID)
	return httperr.New(http.StatusUnauthorized, "INVALID_TWO_FACTOR", "The two-factor authentication code is invalid.")
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
	if strings.TrimSpace(token) == "" {
		return nil
	}
	now := timeutil.NowISO()
	var sessID, userID, username, role, createdAt string
	var email, disabledAt sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT s.id, s.user_id, u.username, u.email, u.role, u.disabled_at, u.created_at
		FROM user_sessions s JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ?`,
		crypto.SHA256Hex(token), now).Scan(&sessID, &userID, &username, &email, &role, &disabledAt, &createdAt)
	if err != nil || (disabledAt.Valid && disabledAt.String != "") {
		return nil
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE user_sessions SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, sessID)
	u := User{ID: userID, Username: username, Email: nullPtr(email), Role: role, CreatedAt: createdAt}
	return &AuthContext{
		Type:      "session",
		SessionID: sessID,
		UserID:    userID,
		Scopes:    []string{"*"},
		User:      u,
	}
}

func (s *Service) Logout(ctx context.Context, sessionID string) error {
	_, err := s.DB.W.ExecContext(ctx, `UPDATE user_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?`, sessionID)
	return err
}

func (s *Service) LogoutAll(ctx context.Context, userID string) error {
	_, err := s.DB.W.ExecContext(ctx, `UPDATE user_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id = ? AND revoked_at IS NULL`, userID)
	return err
}

func (s *Service) ChangePassword(ctx context.Context, userID, currentPassword, newPassword string) error {
	var pwHash string
	err := s.DB.R.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, userID).Scan(&pwHash)
	if err != nil || !crypto.VerifyPassword(currentPassword, pwHash) {
		return httperr.New(http.StatusUnauthorized, "INVALID_PASSWORD", "The current password is incorrect.")
	}
	if len(newPassword) < 12 {
		return httperr.New(http.StatusBadRequest, "WEAK_PASSWORD", "Password must contain at least 12 characters.")
	}
	nextHash, err := crypto.HashPassword(newPassword)
	if err != nil {
		return err
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE users SET password_hash = ? WHERE id = ?`, nextHash, userID); err != nil {
		return err
	}
	return s.LogoutAll(ctx, userID)
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

func (s *Service) BeginTwoFactor(ctx context.Context, userID, username string) (TwoFactorSetup, error) {
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
		pending=1, failed_attempts=0, locked_until=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
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
	buf := make([]byte, 10)
	for i := 0; i < n; i++ {
		if _, err := rand.Read(buf); err != nil {
			return nil, err
		}
		var b strings.Builder
		for j := 0; j < 10; j++ {
			b.WriteByte(recoveryAlphabet[buf[j]&31])
		}
		raw := b.String()
		out[i] = raw[:5] + "-" + raw[5:]
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
	if err != nil || !totp.Verify(secret, code, time.Now()) {
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
	if _, err := tx.ExecContext(ctx, `UPDATE user_two_factor SET pending=0, enabled_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=?`, userID); err != nil {
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
	if _, err := s.verifyIdentity(ctx, userID, password, code); err != nil {
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
	if _, err := s.verifyIdentity(ctx, userID, password, code); err != nil {
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

func (s *Service) verifyIdentity(ctx context.Context, userID, password, code string) (string, error) {
	var pwHash string
	err := s.DB.R.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id = ?`, userID).Scan(&pwHash)
	if err != nil || !passhash.Verify(pwHash, password) {
		return "", httperr.New(http.StatusUnauthorized, "INVALID_PASSWORD", "The password is incorrect.")
	}
	if err := s.VerifySecondFactor(ctx, userID, code); err != nil {
		return "", err
	}
	return pwHash, nil
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

func (s *Service) storedFilePaths(ctx context.Context, userID string) ([]string, error) {
	queries := []string{
		`SELECT temporary_path FROM audio_chunks WHERE user_id=? AND temporary_path IS NOT NULL`,
		`SELECT temporary_path FROM imports WHERE user_id=? AND temporary_path IS NOT NULL`,
		`SELECT p.temporary_path FROM import_parts p JOIN imports i ON i.id=p.import_id WHERE i.user_id=?`,
		`SELECT original_path FROM recording_context_items WHERE user_id=? AND original_path IS NOT NULL`,
		`SELECT local_path FROM cloud_archive_items WHERE user_id=? AND local_path IS NOT NULL`,
		`SELECT local_dir FROM cloud_recording_assemblies WHERE user_id=?`,
	}
	var out []string
	for _, q := range queries {
		rows, err := s.DB.R.QueryContext(ctx, q, userID)
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
	if _, err := s.verifyIdentity(ctx, userID, password, code); err != nil {
		return EraseResult{}, err
	}
	paths, err := s.storedFilePaths(ctx, userID)
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

// DeleteAccount permanently deletes a non-admin account, unlinking all audio first
// and scrubbing PII from audit_log.
func (s *Service) DeleteAccount(ctx context.Context, userID, password, code string, unlinkStrict func(string) error) error {
	var role string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT role FROM users WHERE id = ?`, userID).Scan(&role); err == nil && role == "admin" {
		return httperr.New(http.StatusForbidden, "ADMIN_SELF_DELETE",
			"Admin accounts can’t delete themselves. Ask whoever runs this server to revoke admin with `neorecall admin revoke <username>` first.")
	}
	if _, err := s.verifyIdentity(ctx, userID, password, code); err != nil {
		return err
	}
	paths, err := s.storedFilePaths(ctx, userID)
	if err != nil {
		return err
	}
	for _, p := range paths {
		if unlinkStrict != nil {
			if err := unlinkStrict(p); err != nil {
				return err
			}
		}
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if s.RemoveIndex != nil {
		if err := s.RemoveIndex(ctx, tx, userID); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE audit_log SET actor_id=NULL, ip_address=NULL, metadata_json=NULL, resource_id=NULL
		WHERE actor_type IN ('user','admin') AND actor_id=?`, userID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE audit_log SET ip_address=NULL, metadata_json=NULL WHERE affected_user_id=?`, userID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, userID); err != nil {
		return err
	}
	return tx.Commit()
}

// Unused import sanity helper kept cleanly.
var _ = slices.Contains[[]string, string]
