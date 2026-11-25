package diagnostics

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/publicerr"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

var (
	uuidRe   = regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`)
	bearerRe = regexp.MustCompile(`(?i)Bearer\s+[A-Za-z0-9._~+/=-]+`)
)

func SafePath(v string) string {
	p := strings.SplitN(v, "?", 2)[0]
	if p == "" {
		p = "/"
	}
	p = uuidRe.ReplaceAllString(p, ":id")
	if len(p) > 300 {
		p = p[:300]
	}
	return p
}

func SafeMessage(v string) string {
	if v == "" {
		return ""
	}
	s := publicerr.Sanitize(bearerRe.ReplaceAllString(v, "Bearer [redacted]"), "", "")
	if len(s) > 500 {
		s = s[:500]
	}
	return s
}

type Service struct {
	DB      *dbx.DB
	Cfg     func() config.Config
	Version string
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) RecordRequest(ctx context.Context, userID, requestID, method, path string, statusCode int, durationMs int64, errorCode string) {
	if userID == "" {
		return
	}
	var exists int
	if err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM users WHERE id=?`, userID).Scan(&exists); err != nil {
		return
	}
	c := s.cfg()
	retDays := c.DiagnosticRetentionDays
	if retDays <= 0 {
		retDays = 7
	}
	maxEvents := c.DiagnosticMaxEventsPerUser
	if maxEvents <= 0 {
		maxEvents = 500
	}
	var reqIDNull, errNull sql.NullString
	if requestID != "" {
		reqIDNull = sql.NullString{String: requestID, Valid: true}
	}
	if errorCode != "" {
		if len(errorCode) > 100 {
			errorCode = errorCode[:100]
		}
		errNull = sql.NullString{String: errorCode, Valid: true}
	}
	if len(method) > 12 {
		method = method[:12]
	}
	_, _ = s.DB.W.ExecContext(ctx, `INSERT INTO diagnostic_request_events
		(user_id, request_id, method, path, status_code, duration_ms, error_code)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		userID, reqIDNull, method, SafePath(path), statusCode, max(0, durationMs), errNull)

	cutoff := timeutil.FormatISO(time.Now().AddDate(0, 0, -retDays))
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM diagnostic_request_events WHERE user_id=? AND created_at<?`, userID, cutoff)
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM diagnostic_request_events WHERE user_id=? AND id NOT IN (
		SELECT id FROM diagnostic_request_events WHERE user_id=? ORDER BY id DESC LIMIT ?
	)`, userID, userID, maxEvents)
}

func (s *Service) ExportForUser(ctx context.Context, userID string) (map[string]any, error) {
	c := s.cfg()
	exportMax := c.DiagnosticExportMaxEvents
	if exportMax <= 0 {
		exportMax = 250
	}

	requests := []map[string]any{}
	if rows, err := s.DB.R.QueryContext(ctx, `SELECT method, path, status_code, duration_ms, error_code, created_at
		FROM diagnostic_request_events WHERE user_id=? ORDER BY id DESC LIMIT ?`, userID, exportMax); err == nil {
		for rows.Next() {
			var method, path, created string
			var status, dur int
			var errCode sql.NullString
			if rows.Scan(&method, &path, &status, &dur, &errCode, &created) == nil {
				var ec *string
				if errCode.Valid {
					v := errCode.String
					ec = &v
				}
				requests = append(requests, map[string]any{
					"method": method, "path": path, "statusCode": status, "durationMs": dur, "errorCode": ec, "createdAt": created,
				})
			}
		}
		rows.Close()
	}

	devices := []map[string]any{}
	if rows, err := s.DB.R.QueryContext(ctx, `SELECT platform, kind, CASE WHEN revoked_at IS NULL THEN 0 ELSE 1 END, last_heartbeat_at, created_at
		FROM devices WHERE user_id=? ORDER BY created_at DESC LIMIT 50`, userID); err == nil {
		for rows.Next() {
			var platform, kind, created string
			var revoked int
			var hb sql.NullString
			if rows.Scan(&platform, &kind, &revoked, &hb, &created) == nil {
				var hbp *string
				if hb.Valid {
					v := hb.String
					hbp = &v
				}
				devices = append(devices, map[string]any{
					"platform": platform, "kind": kind, "revoked": revoked, "lastHeartbeatAt": hbp, "createdAt": created,
				})
			}
		}
		rows.Close()
	}

	sessions := queryGroupedCounts(ctx, s.DB, `SELECT status, COUNT(*), MAX(updated_at) FROM recording_sessions WHERE user_id=? GROUP BY status ORDER BY status`, "status", userID)
	chunks := queryGroupedCounts(ctx, s.DB, `SELECT state, COUNT(*), MAX(updated_at) FROM audio_chunks WHERE user_id=? GROUP BY state ORDER BY state`, "state", userID)

	chunkErrors := []map[string]any{}
	if rows, err := s.DB.R.QueryContext(ctx, `SELECT state, error_code, updated_at FROM audio_chunks
		WHERE user_id=? AND error_code IS NOT NULL ORDER BY updated_at DESC LIMIT 30`, userID); err == nil {
		for rows.Next() {
			var st, ec, up string
			if rows.Scan(&st, &ec, &up) == nil {
				chunkErrors = append(chunkErrors, map[string]any{"state": st, "errorCode": ec, "updatedAt": up})
			}
		}
		rows.Close()
	}

	jobs := []map[string]any{}
	if rows, err := s.DB.R.QueryContext(ctx, `SELECT type, status, attempts, max_attempts, last_error_code, updated_at
		FROM jobs WHERE user_id=? ORDER BY updated_at DESC LIMIT 50`, userID); err == nil {
		for rows.Next() {
			var jtype, st, up string
			var att, maxAtt int
			var ec sql.NullString
			if rows.Scan(&jtype, &st, &att, &maxAtt, &ec, &up) == nil {
				var ecp *string
				if ec.Valid {
					v := ec.String
					ecp = &v
				}
				jobs = append(jobs, map[string]any{
					"type": jtype, "status": st, "attempts": att, "maxAttempts": maxAtt, "errorCode": ecp, "updatedAt": up,
				})
			}
		}
		rows.Close()
	}

	imports := []map[string]any{}
	if rows, err := s.DB.R.QueryContext(ctx, `SELECT state, error_code, updated_at FROM imports WHERE user_id=? ORDER BY updated_at DESC LIMIT 30`, userID); err == nil {
		for rows.Next() {
			var st, up string
			var ec sql.NullString
			if rows.Scan(&st, &ec, &up) == nil {
				var ecp *string
				if ec.Valid {
					v := ec.String
					ecp = &v
				}
				imports = append(imports, map[string]any{"state": st, "errorCode": ecp, "updatedAt": up})
			}
		}
		rows.Close()
	}

	ver := s.Version
	if ver == "" {
		ver = config.Version
	}
	return map[string]any{
		"available":   true,
		"generatedAt": timeutil.NowISO(),
		"version":     ver,
		"requests":    requests,
		"accountState": map[string]any{
			"devices": devices, "sessions": sessions, "chunks": chunks,
			"chunkErrors": chunkErrors, "jobs": jobs, "imports": imports,
		},
	}, nil
}

func queryGroupedCounts(ctx context.Context, db *dbx.DB, q, label, userID string) []map[string]any {
	out := []map[string]any{}
	rows, err := db.R.QueryContext(ctx, q, userID)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		var cnt int
		var latest sql.NullString
		if rows.Scan(&key, &cnt, &latest) == nil {
			var lp *string
			if latest.Valid {
				v := latest.String
				lp = &v
			}
			out = append(out, map[string]any{label: key, "count": cnt, "latestAt": lp})
		}
	}
	return out
}

type statusCapture struct {
	http.ResponseWriter
	status int
}

func (w *statusCapture) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusCapture) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Middleware records non-SSE request diagnostics asynchronously or synchronously after response completes.
func (s *Service) Middleware(resolver func(context.Context, string) *auth.AuthContext) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.URL.Path, "/api/v1") || strings.HasPrefix(r.URL.Path, "/api/v1/events") {
				next.ServeHTTP(w, r)
				return
			}
			start := time.Now()
			capW := &statusCapture{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(capW, r)
			var uid string
			if a := auth.FromContext(r.Context()); a != nil {
				uid = a.UserID
			} else if resolver != nil {
				if a := resolver(r.Context(), auth.BearerToken(r)); a != nil {
					uid = a.UserID
				}
			}
			if uid != "" {
				errCode := capW.Header().Get("X-NeoRecall-Error-Code")
				s.RecordRequest(r.Context(), uid, httperr.RequestID(r), r.Method, r.URL.Path, capW.status, time.Since(start).Milliseconds(), errCode)
			}
		})
	}
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	mux.Handle("GET /api/v1/diagnostics/export", rt.Auth.RequireAuth(rt.Auth.RequireSession(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := auth.FromContext(r.Context())
		out, err := rt.Svc.ExportForUser(r.Context(), a.UserID)
		if err != nil {
			httperr.WriteError(w, r, rt.Log, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, out)
	}))))
}
