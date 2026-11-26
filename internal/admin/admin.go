package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

type Service struct {
	DB         *dbx.DB
	Cfg        func() config.Config
	Jobs       *jobs.Service
	Embeddings *embeddings.Service
	Speakers   *speakers.Service
	Usage      *usage.Service
	Backups    *backup.Service
	Updates    *updates.Service
	Version    string
	Log        *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func dirBytes(dir string) int64 {
	if dir == "" {
		return 0
	}
	var total int64
	_ = filepath.WalkDir(dir, func(_ string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

func (s *Service) Stats(ctx context.Context) (map[string]any, error) {
	var failed error
	count := func(q string) int {
		var n int
		failed = errors.Join(failed, s.DB.R.QueryRowContext(ctx, q).Scan(&n))
		return n
	}
	list := func(q string, args ...any) []map[string]any {
		out, err := s.rows(ctx, q, args...)
		failed = errors.Join(failed, err)
		return out
	}
	var oldestQueued sql.NullString
	failed = errors.Join(failed, s.DB.R.QueryRowContext(ctx, `SELECT MIN(created_at) FROM jobs WHERE status='queued'`).Scan(&oldestQueued))

	c := s.cfg()
	chunkBytes, importBytes := dirBytes(c.Paths.AudioTmp), dirBytes(c.Paths.ImportTmp)
	stats := map[string]any{
		"version":              s.Version,
		"users":                count(`SELECT COUNT(*) FROM users`),
		"devices":              count(`SELECT COUNT(*) FROM devices WHERE revoked_at IS NULL`),
		"recordings":           count(`SELECT COUNT(*) FROM recording_sessions`),
		"queue":                list(`SELECT status, COUNT(*) AS count FROM jobs GROUP BY status`),
		"oldestQueuedAt":       nullStr(oldestQueued),
		"workers":              list(`SELECT * FROM worker_heartbeats ORDER BY heartbeat_at DESC`),
		"temporaryAudioBytes":  chunkBytes + importBytes,
		"temporaryChunkBytes":  chunkBytes,
		"temporaryImportBytes": importBytes,
		"cleanupPending":       count(`SELECT COUNT(*) FROM audio_chunks WHERE state='persisted_cleanup_pending'`),
		"vector":               map[string]any{"ready": s.Embeddings != nil && s.Embeddings.VectorReady(), "version": nil},
		"ai": list(`SELECT purpose, COUNT(*) AS attempts, COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
			COALESCE(SUM(completion_tokens),0) AS completion_tokens FROM ai_requests GROUP BY purpose`),
		"processing": list(`SELECT metric, AVG(value) AS average, MAX(value) AS maximum, unit FROM processing_metrics
			WHERE created_at>? GROUP BY metric, unit`, timeutil.FormatISO(time.Now().Add(-24*time.Hour))),
	}
	return stats, failed
}

// rows reads a query into objects keyed by column name.
func (s *Service) rows(ctx context.Context, query string, args ...any) ([]map[string]any, error) {
	rows, err := s.DB.R.QueryContext(ctx, query, args...)
	if err != nil {
		return []map[string]any{}, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return []map[string]any{}, err
	}
	out := []map[string]any{}
	for rows.Next() {
		values := make([]any, len(columns))
		targets := make([]any, len(columns))
		for i := range values {
			targets[i] = &values[i]
		}
		if err := rows.Scan(targets...); err != nil {
			return out, err
		}
		row := make(map[string]any, len(columns))
		for i, column := range columns {
			row[column] = values[i]
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

func (s *Service) Users(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, username, email, role, disabled_at, created_at, last_login_at,
		(SELECT COUNT(*) FROM recording_sessions r WHERE r.user_id=users.id) AS recording_count,
		(SELECT COUNT(*) FROM devices d WHERE d.user_id=users.id) AS device_count
		FROM users ORDER BY created_at DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, uname, role, created string
		var email, disAt, lastLogin sql.NullString
		var recordings, dc int
		if rows.Scan(&id, &uname, &email, &role, &disAt, &created, &lastLogin, &recordings, &dc) == nil {
			out = append(out, map[string]any{
				"id":              id,
				"username":        uname,
				"email":           nullStr(email),
				"role":            role,
				"disabled_at":     nullStr(disAt),
				"created_at":      created,
				"last_login_at":   nullStr(lastLogin),
				"recording_count": recordings,
				"device_count":    dc,
			})
		}
	}
	return out, nil
}

// SetUserDisabled refuses admin accounts, the caller's own included: admin is
// granted and revoked by the operator, so locking one out has to start there.
func (s *Service) SetUserDisabled(ctx context.Context, actorID, userID string, disabled bool) error {
	var role string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT role FROM users WHERE id=?`, userID).Scan(&role); errors.Is(err, sql.ErrNoRows) {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "User not found.")
	} else if err != nil {
		return err
	}
	if disabled && role == "admin" {
		return httperr.New(http.StatusForbidden, "ADMIN_ACCOUNT", "Admin accounts can’t be disabled here. Revoke admin with `neorecall admin revoke <username>` first.")
	}
	var err error
	if disabled {
		_, err = s.DB.W.ExecContext(ctx, `UPDATE users SET disabled_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, userID)
		if err == nil {
			// Disabled accounts are refused on every request; this also ends the
			// sessions so re-enabling does not revive them.
			_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM sessions WHERE CAST(json_extract(sess, '$.userId') AS TEXT)=?`, userID)
		}
	} else {
		_, err = s.DB.W.ExecContext(ctx, `UPDATE users SET disabled_at=NULL WHERE id=?`, userID)
	}
	if err != nil {
		return err
	}
	action := "admin.user_enabled"
	if disabled {
		action = "admin.user_disabled"
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{
		ActorType: "admin", ActorID: actorID, AffectedUserID: userID,
		Action: action, ResourceType: "user", ResourceID: userID,
	})
	return nil
}

func (s *Service) ListJobs(ctx context.Context, statusFilter, typeFilter, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	var conds []string
	var args []any
	if statusFilter != "" {
		conds = append(conds, "status=?")
		args = append(args, statusFilter)
	}
	if typeFilter != "" {
		conds = append(conds, "type=?")
		args = append(args, typeFilter)
	}
	where := ""
	if len(conds) > 0 {
		where = "WHERE " + strings.Join(conds, " AND ")
	}
	args = append(args, lim)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, user_id, resource_type, resource_id, type, status, priority,
		attempts, max_attempts, next_attempt_at, last_error_code, last_error_message, created_at, updated_at, completed_at,
		lease_owner, lease_expires_at, payload_json, started_at
		FROM jobs `+where+` ORDER BY created_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, jtype, st, runAfter, created, updated string
		var uid, rtype, rid, ec, em, compAt, leaseOwner, leaseExpires, startedAt sql.NullString
		var payload string
		var prio, att, maxAtt int
		if rows.Scan(&id, &uid, &rtype, &rid, &jtype, &st, &prio, &att, &maxAtt, &runAfter, &ec, &em, &created, &updated, &compAt, &leaseOwner, &leaseExpires, &payload, &startedAt) == nil {
			out = append(out, map[string]any{
				"id":                 id,
				"user_id":            nullStr(uid),
				"resource_type":      nullStr(rtype),
				"resource_id":        nullStr(rid),
				"type":               jtype,
				"status":             st,
				"priority":           prio,
				"attempts":           att,
				"max_attempts":       maxAtt,
				"next_attempt_at":    runAfter,
				"last_error_code":    nullStr(ec),
				"last_error_message": nullStr(em),
				"created_at":         created,
				"updated_at":         updated,
				"completed_at":       nullStr(compAt),
				"lease_owner":        nullStr(leaseOwner),
				"lease_expires_at":   nullStr(leaseExpires),
				"payload_json":       payload,
				"started_at":         nullStr(startedAt),
			})
		}
	}
	return out, nil
}

func (s *Service) RetryJob(ctx context.Context, id string) error {
	if !s.Jobs.Retry(ctx, id) {
		return httperr.New(http.StatusConflict, "JOB_NOT_RETRYABLE", "Job is not in a retryable state.")
	}
	return nil
}

func (s *Service) CancelJob(ctx context.Context, id string) error {
	if !s.Jobs.Cancel(ctx, id) {
		return httperr.New(http.StatusConflict, "JOB_NOT_CANCELLABLE", "Job is not in a cancellable state.")
	}
	return nil
}

func (s *Service) AIRequests(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, user_id, purpose, provider, model, state, http_status,
		error_code, prompt_tokens, completion_tokens, reserved_at, sent_at, completed_at
		FROM ai_requests ORDER BY reserved_at DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, purpose, prov, model, state, resAt string
		var uid, ec, sentAt, compAt sql.NullString
		var httpSt, pt, ct sql.NullInt64
		if rows.Scan(&id, &uid, &purpose, &prov, &model, &state, &httpSt, &ec, &pt, &ct, &resAt, &sentAt, &compAt) == nil {
			out = append(out, map[string]any{
				"id":                id,
				"user_id":           nullStr(uid),
				"purpose":           purpose,
				"provider":          prov,
				"model":             model,
				"state":             state,
				"http_status":       nullInt(httpSt),
				"error_code":        nullStr(ec),
				"prompt_tokens":     nullInt(pt),
				"completion_tokens": nullInt(ct),
				"reserved_at":       resAt,
				"sent_at":           nullStr(sentAt),
				"completed_at":      nullStr(compAt),
			})
		}
	}
	return out, nil
}

func (s *Service) AuditLog(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT a.id, a.actor_type, a.actor_id, a.affected_user_id, a.action, a.resource_type, a.resource_id, a.ip_address, a.metadata_json, a.created_at, actor.username, affected.username
  FROM audit_log a LEFT JOIN users actor ON a.actor_type IN ('user','admin') AND actor.id=a.actor_id LEFT JOIN users affected ON affected.id=a.affected_user_id ORDER BY a.id DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id int64
		var at, action, created string
		var aid, aff, rt, rid, ip, meta, actorName, affectedName sql.NullString
		if rows.Scan(&id, &at, &aid, &aff, &action, &rt, &rid, &ip, &meta, &created, &actorName, &affectedName) == nil {
			out = append(out, map[string]any{
				"id":                id,
				"actor_type":        at,
				"actor_id":          nullStr(aid),
				"actor_username":    nullStr(actorName),
				"affected_username": nullStr(affectedName),
				"affected_user_id":  nullStr(aff),
				"action":            action,
				"resource_type":     nullStr(rt),
				"resource_id":       nullStr(rid),
				"ip_address":        nullStr(ip),
				"metadata_json":     nullStr(meta),
				"created_at":        created,
			})
		}
	}
	return out, nil
}

func (s *Service) RequeueQuarantined(ctx context.Context) (int64, error) {
	res, err := s.DB.W.ExecContext(ctx, `UPDATE conversations SET quarantined_at=NULL, quarantine_reason=NULL,
		consolidation_failures=0, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
		WHERE quarantined_at IS NOT NULL`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func nullStr(s sql.NullString) any {
	if s.Valid {
		return s.String
	}
	return nil
}

func nullInt(i sql.NullInt64) any {
	if i.Valid {
		return i.Int64
	}
	return nil
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	adm := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAdmin(h))
	}
	mux.Handle("GET /api/v1/admin/stats", adm(rt.handleStats))
	mux.Handle("GET /api/v1/admin/users", adm(rt.handleUsers))
	mux.Handle("PATCH /api/v1/admin/users/{id}", adm(rt.handlePatchUser))
	mux.Handle("GET /api/v1/admin/jobs", adm(rt.handleJobs))
	mux.Handle("POST /api/v1/admin/jobs/{id}/retry", adm(rt.handleRetryJob))
	mux.Handle("POST /api/v1/admin/jobs/{id}/cancel", adm(rt.handleCancelJob))
	mux.Handle("GET /api/v1/admin/ai-requests", adm(rt.handleAIRequests))
	mux.Handle("GET /api/v1/admin/audit", adm(rt.handleAudit))
	mux.Handle("GET /api/v1/admin/config/usage-limits", adm(rt.handleGetDefaultsLegacy))
	mux.Handle("PUT /api/v1/admin/config/usage-limits", adm(rt.handlePutDefaultsLegacy))
	mux.Handle("GET /api/v1/admin/users/{id}/usage-limits", adm(rt.handleGetUserLimits))
	mux.Handle("PUT /api/v1/admin/users/{id}/usage-limits", adm(rt.handlePutUserLimits))
	mux.Handle("GET /api/v1/admin/usage-limits", adm(rt.handleGetDefaults))
	mux.Handle("PUT /api/v1/admin/usage-limits", adm(rt.handlePutDefaults))
	mux.Handle("GET /api/v1/admin/users/{id}/limits", adm(rt.handleGetUserLimits))
	mux.Handle("PUT /api/v1/admin/users/{id}/limits", adm(rt.handlePutUserLimits))
	mux.Handle("POST /api/v1/admin/reindex", adm(rt.handleReindex))
	mux.Handle("POST /api/v1/admin/quarantined/requeue", adm(rt.handleRequeueQuarantined))
	mux.Handle("POST /api/v1/admin/speakers/reevaluate", adm(rt.handleSpeakerReevaluate))

	mux.Handle("GET /api/v1/admin/backups", adm(rt.handleBackupsStatus))
	mux.Handle("POST /api/v1/admin/backups/run", adm(rt.handleBackupCreate))
	mux.Handle("POST /api/v1/admin/backups", adm(rt.handleBackupCreate))
	mux.Handle("GET /api/v1/admin/backups/{key}/download", adm(rt.handleBackupDownload))
	mux.Handle("DELETE /api/v1/admin/backups/{key}", adm(rt.handleBackupDelete))

	mux.Handle("GET /api/v1/admin/update", adm(rt.handleUpdateStatus))
	mux.Handle("POST /api/v1/admin/update", adm(rt.handleUpdateStart))
	mux.Handle("POST /api/v1/admin/update/check", adm(rt.handleUpdateCheck))
	mux.Handle("PUT /api/v1/admin/update/channel", adm(rt.handleUpdateChannel))

	mux.Handle("GET /api/v1/admin/updates", adm(rt.handleUpdateStatus))
	mux.Handle("POST /api/v1/admin/updates/check", adm(rt.handleUpdateCheck))
	mux.Handle("PUT /api/v1/admin/updates/channel", adm(rt.handleUpdateChannel))
	mux.Handle("POST /api/v1/admin/updates/start", adm(rt.handleUpdateStart))
}

func (rt *Routes) handleStats(w http.ResponseWriter, r *http.Request) {
	stats, err := rt.Svc.Stats(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, stats)
}

func (rt *Routes) handleUsers(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.Users(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items, "users": items})
}

func (rt *Routes) handlePatchUser(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Disabled *bool `json:"disabled"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil || body.Disabled == nil {
		if err != nil {
			httperr.WriteError(w, r, rt.Log, err)
		} else {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "disabled boolean is required."))
		}
		return
	}
	if err := rt.Svc.SetUserDisabled(r.Context(), a.UserID, r.PathValue("id"), *body.Disabled); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleJobs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	items, err := rt.Svc.ListJobs(r.Context(), q.Get("status"), q.Get("type"), q.Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items, "jobs": items})
}

func (rt *Routes) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	if err := rt.Svc.RetryJob(r.Context(), r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	if err := rt.Svc.CancelJob(r.Context(), r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleAIRequests(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.AIRequests(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items, "requests": items})
}

func (rt *Routes) handleAudit(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.AuditLog(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items, "entries": items})
}

func (rt *Routes) handleGetDefaults(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, rt.Svc.Usage.GetInstallDefaults(r.Context()))
}

func (rt *Routes) handlePutDefaults(w http.ResponseWriter, r *http.Request) {
	var body map[string]*int
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.Usage.SetInstallDefaults(r.Context(), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleGetUserLimits(w http.ResponseWriter, r *http.Request) {
	res, err := rt.Svc.Usage.GetUserLimits(r.Context(), r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handlePutUserLimits(w http.ResponseWriter, r *http.Request) {
	var patch usage.UserLimitsPatch
	if err := httperr.DecodeJSON(r, &patch); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.Usage.SetUserLimits(r.Context(), r.PathValue("id"), patch)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleReindex(w http.ResponseWriter, r *http.Request) {
	n, err := rt.Svc.Embeddings.ReindexAll(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"queued": n})
}

func (rt *Routes) handleRequeueQuarantined(w http.ResponseWriter, r *http.Request) {
	n, err := rt.Svc.RequeueQuarantined(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"requeued": n})
}

func (rt *Routes) handleSpeakerReevaluate(w http.ResponseWriter, r *http.Request) {
	if rt.Svc.Speakers == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"users": 0})
		return
	}
	rows, err := rt.Svc.DB.R.QueryContext(r.Context(), `SELECT id FROM users WHERE disabled_at IS NULL`)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	var uids []string
	for rows.Next() {
		var u string
		if rows.Scan(&u) == nil {
			uids = append(uids, u)
		}
	}
	rows.Close()
	users := 0
	for _, u := range uids {
		if _, err := rt.Svc.Speakers.Reevaluate(r.Context(), u, true); err == nil {
			users++
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"users": users})
}

func (rt *Routes) handleBackupsStatus(w http.ResponseWriter, r *http.Request) {
	status, err := rt.Svc.Backups.Overview(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	history, err := rt.Svc.Backups.History(r.Context(), transcripts.PageLimit(r.URL.Query().Get("limit"), 100, 20))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": status, "history": history})
}

func (rt *Routes) handleBackupCreate(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	result, err := rt.Svc.Backups.Run(r.Context(), "manual")
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if err := audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "backup_run", ResourceType: "backup", ResourceID: result.Key,
	}); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, result)
}

func (rt *Routes) handleBackupDownload(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	f, info, err := rt.Svc.Backups.OpenDownload(key)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusNotFound, "BACKUP_NOT_FOUND", err.Error()))
		return
	}
	defer f.Close()
	safeKey := strings.ReplaceAll(filepath.Base(key), `"`, "")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, safeKey))
	w.Header().Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, f)
}

func (rt *Routes) handleBackupDelete(w http.ResponseWriter, r *http.Request) {
	dst, err := rt.Svc.Backups.Destination()
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if err := dst.Remove(r.PathValue("key")); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_BACKUP_KEY", err.Error()))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

func (rt *Routes) handleUpdateStatus(w http.ResponseWriter, _ *http.Request) {
	if rt.Svc.Updates == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"selfUpdate": false})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, rt.Svc.Updates.Status())
}

func (rt *Routes) handleUpdateCheck(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, rt.Svc.Updates.Check())
}

func (rt *Routes) handleUpdateChannel(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Channel string `json:"channel"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.Updates.SetChannel(body.Channel)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleUpdateStart(w http.ResponseWriter, r *http.Request) {
	res, err := rt.Svc.Updates.Start()
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, res)
}

func (rt *Routes) handleGetDefaultsLegacy(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"limits": rt.Svc.Usage.GetInstallDefaults(r.Context())})
}
func (rt *Routes) handlePutDefaultsLegacy(w http.ResponseWriter, r *http.Request) {
	var body map[string]*int
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	res, err := rt.Svc.Usage.SetInstallDefaults(r.Context(), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"limits": res})
}
