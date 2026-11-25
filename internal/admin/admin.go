package admin

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"

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

func (s *Service) Stats(ctx context.Context) map[string]any {
	count := func(q string) int {
		var n int
		_ = s.DB.R.QueryRowContext(ctx, q).Scan(&n)
		return n
	}
	groupCount := func(q string) []map[string]any {
		rows, err := s.DB.R.QueryContext(ctx, q)
		if err != nil {
			return []map[string]any{}
		}
		defer rows.Close()
		out := []map[string]any{}
		for rows.Next() {
			var k string
			var cnt int
			if rows.Scan(&k, &cnt) == nil {
				out = append(out, map[string]any{"key": k, "count": cnt})
			}
		}
		return out
	}

	c := s.cfg()
	tempBytes := dirBytes(c.Paths.AudioTmp) + dirBytes(c.Paths.ImportTmp) + dirBytes(c.Paths.CloudPending)
	return map[string]any{
		"users":          count(`SELECT COUNT(*) FROM users`),
		"activeUsers":    count(`SELECT COUNT(*) FROM users WHERE disabled_at IS NULL`),
		"sessions":       count(`SELECT COUNT(*) FROM recording_sessions`),
		"chunksByState":  groupCount(`SELECT state, COUNT(*) FROM audio_chunks GROUP BY state`),
		"jobsByStatus":   groupCount(`SELECT status, COUNT(*) FROM jobs GROUP BY status`),
		"conversations":  count(`SELECT COUNT(*) FROM conversations`),
		"quarantined":    count(`SELECT COUNT(*) FROM conversations WHERE quarantined_at IS NOT NULL`),
		"memories":       count(`SELECT COUNT(*) FROM memories`),
		"miniMemories":   count(`SELECT COUNT(*) FROM mini_memories`),
		"voiceprints":    count(`SELECT COUNT(*) FROM voiceprints`),
		"searchDocs":     count(`SELECT COUNT(*) FROM search_documents`),
		"embeddings":     count(`SELECT COUNT(*) FROM search_embeddings`),
		"aiRequests":     count(`SELECT COUNT(*) FROM ai_requests`),
		"temporaryBytes": tempBytes,
	}
}

func (s *Service) Users(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, username, email, role, disabled_at, created_at, last_login_at,
		(SELECT COUNT(*) FROM memories m WHERE m.user_id=users.id) AS memory_count,
		(SELECT COUNT(*) FROM devices d WHERE d.user_id=users.id AND d.revoked_at IS NULL) AS device_count
		FROM users ORDER BY created_at DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, uname, role, created string
		var email, disAt, lastLogin sql.NullString
		var mc, dc int
		if rows.Scan(&id, &uname, &email, &role, &disAt, &created, &lastLogin, &mc, &dc) == nil {
			out = append(out, map[string]any{
				"id":            id,
				"username":      uname,
				"email":         nullStr(email),
				"role":          role,
				"disabled_at":   nullStr(disAt),
				"created_at":    created,
				"last_login_at": nullStr(lastLogin),
				"memoryCount":   mc,
				"deviceCount":   dc,
			})
		}
	}
	return out, nil
}

func (s *Service) SetUserDisabled(ctx context.Context, actorID, userID string, disabled bool) (map[string]any, error) {
	if actorID == userID && disabled {
		return nil, httperr.New(http.StatusBadRequest, "CANNOT_DISABLE_SELF", "An admin cannot disable their own account.")
	}
	var res sql.Result
	var err error
	if disabled {
		res, err = s.DB.W.ExecContext(ctx, `UPDATE users SET disabled_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, userID)
		if err == nil {
			_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM user_sessions WHERE user_id=?`, userID)
		}
	} else {
		res, err = s.DB.W.ExecContext(ctx, `UPDATE users SET disabled_at=NULL WHERE id=?`, userID)
	}
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, httperr.New(http.StatusNotFound, "USER_NOT_FOUND", "User not found.")
	}
	action := "admin.user_enabled"
	if disabled {
		action = "admin.user_disabled"
	}
	_ = audit.Record(ctx, s.DB, audit.Entry{
		ActorType: "admin", ActorID: actorID, AffectedUserID: userID,
		Action: action, ResourceType: "user", ResourceID: userID,
	})
	return map[string]any{"id": userID, "disabled": disabled}, nil
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
		attempts, max_attempts, run_after, last_error_code, last_error_message, created_at, updated_at, completed_at
		FROM jobs `+where+` ORDER BY created_at DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, rtype, rid, jtype, st, runAfter, created, updated string
		var uid, ec, em, compAt sql.NullString
		var prio, att, maxAtt int
		if rows.Scan(&id, &uid, &rtype, &rid, &jtype, &st, &prio, &att, &maxAtt, &runAfter, &ec, &em, &created, &updated, &compAt) == nil {
			out = append(out, map[string]any{
				"id":                 id,
				"user_id":            nullStr(uid),
				"resource_type":      rtype,
				"resource_id":        rid,
				"type":               jtype,
				"status":             st,
				"priority":           prio,
				"attempts":           att,
				"max_attempts":       maxAtt,
				"run_after":          runAfter,
				"last_error_code":    nullStr(ec),
				"last_error_message": nullStr(em),
				"created_at":         created,
				"updated_at":         updated,
				"completed_at":       nullStr(compAt),
			})
		}
	}
	return out, nil
}

func (s *Service) RetryJob(ctx context.Context, id string) (map[string]any, error) {
	if !s.Jobs.Retry(ctx, id) {
		return nil, httperr.New(http.StatusNotFound, "JOB_NOT_FOUND", "Job not found or not retryable.")
	}
	return map[string]any{"id": id, "status": "queued"}, nil
}

func (s *Service) CancelJob(ctx context.Context, id string) (map[string]any, error) {
	if !s.Jobs.Cancel(ctx, id) {
		return nil, httperr.New(http.StatusNotFound, "JOB_NOT_FOUND", "Job not found or already terminal.")
	}
	return map[string]any{"id": id, "status": "cancelled"}, nil
}

func (s *Service) AIRequests(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, user_id, purpose, provider, model, state, http_status,
		error_code, prompt_tokens, completion_tokens, reserved_at, completed_at
		FROM ai_requests ORDER BY reserved_at DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, purpose, prov, model, state, resAt string
		var uid, ec, compAt sql.NullString
		var httpSt, pt, ct sql.NullInt64
		if rows.Scan(&id, &uid, &purpose, &prov, &model, &state, &httpSt, &ec, &pt, &ct, &resAt, &compAt) == nil {
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
				"completed_at":      nullStr(compAt),
			})
		}
	}
	return out, nil
}

func (s *Service) AuditLog(ctx context.Context, limitRaw string) ([]map[string]any, error) {
	lim := transcripts.PageLimit(limitRaw, 200, 50)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, actor_type, actor_id, affected_user_id, action, resource_type, resource_id, ip_address, metadata_json, created_at
		FROM audit_log ORDER BY id DESC LIMIT ?`, lim)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id int64
		var at, action, created string
		var aid, aff, rt, rid, ip, meta sql.NullString
		if rows.Scan(&id, &at, &aid, &aff, &action, &rt, &rid, &ip, &meta, &created) == nil {
			out = append(out, map[string]any{
				"id":               id,
				"actor_type":       at,
				"actor_id":         nullStr(aid),
				"affected_user_id": nullStr(aff),
				"action":           action,
				"resource_type":    nullStr(rt),
				"resource_id":      nullStr(rid),
				"ip_address":       nullStr(ip),
				"metadata_json":    nullStr(meta),
				"created_at":       created,
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
	mux.Handle("GET /api/v1/admin/usage-limits", adm(rt.handleGetDefaults))
	mux.Handle("PUT /api/v1/admin/usage-limits", adm(rt.handlePutDefaults))
	mux.Handle("GET /api/v1/admin/users/{id}/limits", adm(rt.handleGetUserLimits))
	mux.Handle("PUT /api/v1/admin/users/{id}/limits", adm(rt.handlePutUserLimits))
	mux.Handle("POST /api/v1/admin/reindex", adm(rt.handleReindex))
	mux.Handle("POST /api/v1/admin/quarantined/requeue", adm(rt.handleRequeueQuarantined))
	mux.Handle("POST /api/v1/admin/speakers/reevaluate", adm(rt.handleSpeakerReevaluate))

	mux.Handle("GET /api/v1/admin/backups", adm(rt.handleBackupsStatus))
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
	httpx.WriteJSON(w, http.StatusOK, rt.Svc.Stats(r.Context()))
}

func (rt *Routes) handleUsers(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.Users(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
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
	res, err := rt.Svc.SetUserDisabled(r.Context(), a.UserID, r.PathValue("id"), *body.Disabled)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleJobs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	items, err := rt.Svc.ListJobs(r.Context(), q.Get("status"), q.Get("type"), q.Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	res, err := rt.Svc.RetryJob(r.Context(), r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	res, err := rt.Svc.CancelJob(r.Context(), r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleAIRequests(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.AIRequests(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (rt *Routes) handleAudit(w http.ResponseWriter, r *http.Request) {
	items, err := rt.Svc.AuditLog(r.Context(), r.URL.Query().Get("limit"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"items": items})
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
	if rt.Svc.Backups == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"enabled": false, "items": []any{}})
		return
	}
	res, err := rt.Svc.Backups.Status()
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleBackupCreate(w http.ResponseWriter, r *http.Request) {
	art, err := rt.Svc.Backups.Create(r.Context())
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, art)
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
