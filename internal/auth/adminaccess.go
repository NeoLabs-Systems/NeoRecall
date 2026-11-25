package auth

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

type AdminEntry struct {
	ID       string `json:"id"`
	Username string `json:"username"`
}

type AdminChange struct {
	Username string `json:"username"`
	Changed  bool   `json:"changed"`
}

type EnvGrantResult struct {
	Granted []string
	Missing []string
	Revoked []string
}

func foldASCIILower(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		b.WriteByte(c)
	}
	return b.String()
}

func (s *Service) IsAdminUser(ctx context.Context, userID string) bool {
	var role string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT role FROM users WHERE id = ?`, userID).Scan(&role); err != nil {
		return false
	}
	return role == "admin"
}

func (s *Service) ListAdmins(ctx context.Context) ([]AdminEntry, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, username FROM users WHERE role = 'admin' ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AdminEntry{}
	for rows.Next() {
		var a AdminEntry
		if err := rows.Scan(&a.ID, &a.Username); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Service) setRole(ctx context.Context, username, role, source string) (AdminChange, error) {
	name := strings.TrimSpace(username)
	var id, curName, curRole string
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, role FROM users WHERE username = ? COLLATE NOCASE`, name).
		Scan(&id, &curName, &curRole)
	if errors.Is(err, sql.ErrNoRows) {
		return AdminChange{}, httperr.New(http.StatusNotFound, "NOT_FOUND", `No account named "`+name+`".`)
	}
	if err != nil {
		return AdminChange{}, err
	}
	if curRole == role {
		return AdminChange{Username: curName, Changed: false}, nil
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return AdminChange{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE users SET role = ? WHERE id = ?`, role, id); err != nil {
		return AdminChange{}, err
	}
	action := "admin_granted"
	if role != "admin" {
		action = "admin_revoked"
	}
	if err := audit.RecordExec(ctx, tx, audit.Entry{
		ActorType:      "system",
		AffectedUserID: id,
		Action:         action,
		Metadata:       map[string]string{"source": source},
	}); err != nil {
		return AdminChange{}, err
	}
	if err := tx.Commit(); err != nil {
		return AdminChange{}, err
	}
	return AdminChange{Username: curName, Changed: true}, nil
}

func (s *Service) GrantAdmin(ctx context.Context, username, source string) (AdminChange, error) {
	return s.setRole(ctx, username, "admin", source)
}

func (s *Service) RevokeAdmin(ctx context.Context, username, source string) (AdminChange, error) {
	return s.setRole(ctx, username, "user", source)
}

// IsReservedAdminUsername checks whether username matches an entry in NEORECALL_ADMIN_USERS
// that does not yet have an account in SQLite.
func (s *Service) IsReservedAdminUsername(ctx context.Context, username string) bool {
	norm := foldASCIILower(strings.TrimSpace(username))
	for _, listed := range s.cfg().AdminUsers {
		if foldASCIILower(listed) != norm {
			continue
		}
		var one int
		if err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM users WHERE username = ? COLLATE NOCASE`, listed).Scan(&one); errors.Is(err, sql.ErrNoRows) {
			return true
		}
	}
	return false
}

func (s *Service) wasRevokedByOperator(ctx context.Context, userID string) bool {
	var action string
	err := s.DB.R.QueryRowContext(ctx, `SELECT action FROM audit_log
		WHERE affected_user_id = ? AND action IN ('admin_granted', 'admin_revoked')
		ORDER BY id DESC LIMIT 1`, userID).Scan(&action)
	return err == nil && action == "admin_revoked"
}

// ApplyEnvAdminGrants grants admin to existing accounts named in NEORECALL_ADMIN_USERS
// unless explicitly revoked by the operator.
func (s *Service) ApplyEnvAdminGrants(ctx context.Context) (EnvGrantResult, error) {
	var res EnvGrantResult
	for _, name := range s.cfg().AdminUsers {
		var id, role string
		err := s.DB.R.QueryRowContext(ctx, `SELECT id, role FROM users WHERE username = ? COLLATE NOCASE`, name).Scan(&id, &role)
		if errors.Is(err, sql.ErrNoRows) {
			res.Missing = append(res.Missing, name)
			continue
		}
		if err != nil {
			return res, err
		}
		if role != "admin" && s.wasRevokedByOperator(ctx, id) {
			res.Revoked = append(res.Revoked, name)
			continue
		}
		ch, err := s.GrantAdmin(ctx, name, "env")
		if err != nil {
			return res, err
		}
		if ch.Changed {
			res.Granted = append(res.Granted, name)
		}
	}
	return res, nil
}

func (s *Service) NeedsAdminGrant(ctx context.Context) bool {
	var accounts, admins int
	if err := s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(role = 'admin'), 0) FROM users`).Scan(&accounts, &admins); err != nil {
		return false
	}
	return accounts > 0 && admins == 0
}
