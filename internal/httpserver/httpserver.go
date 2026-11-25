// Package httpserver assembles NeoRecall's HTTP server: security headers,
// CORS, rate limiting, diagnostics, health/ready, public status, analytics, and SPA/landing assets.
package httpserver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/secheaders"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/diagnostics"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

const (
	countlyEndpoint = "https://data.neo.eu.com/i"
	countlyOrigin   = "https://data.neo.eu.com"
	countlyAppKey   = "f692479644d216d4224ba5a5da7f3e91ccf8e2e3"
	statusHours     = 48
	statusSampleInt = 5 * time.Minute
	apiRateWindow   = 5 * time.Minute
	apiRateLimit    = 2000
	jsonBodyLimit   = 1 << 20
)

type Mountable interface {
	Mount(mux *http.ServeMux)
}

type Deps struct {
	Config   func() config.Config
	DB       *dbx.DB
	Log      *slog.Logger
	Version  string
	Now      func() time.Time
	Getenv   func(string) string
	Auth     *auth.Authenticator
	Diag     *diagnostics.Service
	AIReady  func(context.Context) bool
	STTReady func(context.Context) bool
	VecReady func() bool
	Routes   []Mountable
}

func (d Deps) cfg() config.Config {
	if d.Config != nil {
		return d.Config()
	}
	return config.Config{}
}

func (d Deps) analyticsOn() bool {
	if d.Getenv == nil {
		return false
	}
	v := strings.ToLower(strings.TrimSpace(d.Getenv("ANALYTICS_ENABLED")))
	switch v {
	case "false", "0", "off", "no":
		return false
	default:
		return true
	}
}

func SecurityHeaders(cfg config.Config, analyticsOrigin string) secheaders.Config {
	hsts := 0
	if cfg.Production {
		hsts = 31536000
	}
	connectSrc := []string{"'self'", "ws:", "wss:"}
	if analyticsOrigin != "" {
		connectSrc = append(connectSrc, analyticsOrigin)
	}
	return secheaders.Config{
		HSTSMaxAgeSeconds: hsts,
		PermissionsPolicy: "camera=(self), geolocation=(self), microphone=(self), payment=(), usb=()",
		CSP: secheaders.Policy{
			{Name: "default-src", Values: []string{"'self'"}},
			{Name: "base-uri", Values: []string{"'self'"}},
			{Name: "font-src", Values: []string{"'self'", "data:", "https://fonts.gstatic.com"}},
			{Name: "form-action", Values: []string{"'self'"}},
			{Name: "frame-ancestors", Values: []string{"'self'"}},
			{Name: "img-src", Values: []string{"'self'", "data:", "blob:"}},
			{Name: "object-src", Values: []string{"'none'"}},
			{Name: "script-src", Values: []string{"'self'", "'unsafe-inline'", "'unsafe-eval'", "'wasm-unsafe-eval'", "blob:"}},
			{Name: "script-src-attr", Values: []string{"'unsafe-inline'"}},
			{Name: "style-src", Values: []string{"'self'", "'unsafe-inline'", "https://fonts.googleapis.com"}},
			{Name: "media-src", Values: []string{"'self'", "data:", "blob:"}},
			{Name: "connect-src", Values: connectSrc},
			{Name: "worker-src", Values: []string{"'self'", "blob:"}},
		},
	}
}

func New(d Deps) http.Handler {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Getenv == nil {
		d.Getenv = os.Getenv
	}
	ver := d.Version
	if ver == "" {
		ver = config.Version
	}
	c := d.cfg()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"status":  "ok",
			"process": "http",
			"version": ver,
		})
	})
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
		dbOK, workerOK, sttOK, llmOK, vecOK := inspectReadiness(r.Context(), d)
		ready := dbOK && workerOK && sttOK && llmOK && vecOK
		code := http.StatusServiceUnavailable
		statusText := "not_ready"
		if ready {
			code = http.StatusOK
			statusText = "ready"
		}
		httpx.WriteJSON(w, code, map[string]any{
			"status":        statusText,
			"database":      dbOK,
			"worker":        workerOK,
			"models":        sttOK,
			"languageModel": llmOK,
			"vector":        vecOK,
			"vectorVersion": "native-go",
		})
	})

	hist := newStatusHistory(c.Paths.Data, d.Now)
	mux.HandleFunc("GET /api/public/status", func(w http.ResponseWriter, r *http.Request) {
		st := buildPublicStatus(r.Context(), d)
		st["history"] = hist.history()
		w.Header().Set("Cache-Control", "no-store")
		httpx.WriteJSON(w, http.StatusOK, st)
	})

	if d.Auth != nil {
		mux.Handle("GET /api/v1/meta", d.Auth.RequireAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cur := d.cfg()
			a := auth.FromContext(r.Context())
			httpx.WriteJSON(w, http.StatusOK, map[string]any{
				"product": "NeoRecall",
				"version": ver,
				"user":    a.User,
				"capabilities": map[string]any{
					"localTranscription": false,
					"diarization":        cur.DiarizationEnabled,
					"semanticSearch":     true,
					"recordingContext":   true,
					"displayAudio":       "client-dependent",
					"wearableStreaming":  false,
					"oauthPublicRoutes":  true,
					"mcp":                true,
					"gzipAudioUpload":    true,
					"plaudEmbedded":      cur.PlaudClientID != "" && cur.PlaudClientSecret != "",
				},
				"limits": map[string]any{
					"maxUploadBytes":                 cur.MaxUploadBytes,
					"chunkMinMs":                     cur.ChunkMinMs,
					"chunkMaxMs":                     cur.ChunkMaxMs,
					"chunkTargetMs":                  cur.ChunkTargetMs,
					"chunkOverlapMs":                 cur.ChunkOverlapMs,
					"importPartBytes":                cur.ImportPartBytes,
					"minimumConsolidationIntervalMs": cur.MinConsolidationIntervalMs,
					"memoryMergeMaxItems":            cur.MemoryMergeMaxItems,
					"chunkReceiptBatch":              config.ChunkReceiptBatchLimit,
					"contextMaxFileBytes":            cur.ContextMaxFileBytes,
					"contextNoteMaxCharacters":       cur.ContextNoteMaxCharacters,
					"contextMaxItems":                cur.ContextMaxItems,
				},
			})
		})))
	}

	for _, rt := range d.Routes {
		if rt != nil {
			rt.Mount(mux)
		}
	}

	adminMoved := func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteError(w, r, d.Log, httperr.New(http.StatusGone, "ADMIN_API_MOVED",
			"The admin API moved to /api/v1/admin and needs a signed-in admin account. Update the NeoRecall app."))
	}
	mux.HandleFunc("/admin/api", adminMoved)
	mux.HandleFunc("/admin/api/", adminMoved)
	mux.HandleFunc("/admin", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/app/", http.StatusFound)
	})
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/admin/api") {
			adminMoved(w, r)
			return
		}
		http.Redirect(w, r, "/app/", http.StatusFound)
	})

	if d.analyticsOn() {
		mux.HandleFunc("GET /_neolabs/analytics.js", func(w http.ResponseWriter, r *http.Request) {
			cfgJSON, _ := json.Marshal(map[string]string{"endpoint": countlyEndpoint, "appKey": countlyAppKey})
			script := strings.Replace(analyticsClientTemplate, "/* COUNTLY_CONFIG */ null", string(cfgJSON), 1)
			setNoStore(w.Header())
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
			_, _ = io.WriteString(w, script)
		})
	}

	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteError(w, r, d.Log, httperr.New(http.StatusNotFound, "NOT_FOUND", "Not found"))
	})

	mux.Handle("/app", http.RedirectHandler("/app/", http.StatusMovedPermanently))
	mux.Handle("/app/", flutterApp(func() string { return d.cfg().WebDir }, d.analyticsOn()))
	mux.Handle("/", landingHandler(func() string { return d.cfg().Landing }, d.analyticsOn()))

	lim := httperr.NewSlidingLimiter(apiRateWindow, apiRateLimit, "RATE_LIMITED", func(r *http.Request) string {
		if a := auth.FromContext(r.Context()); a != nil && a.UserID != "" {
			return a.UserID
		}
		return httperr.ClientIP(r, d.cfg().TrustProxy)
	})

	var diags httpx.Middleware = func(next http.Handler) http.Handler {
		if d.Diag != nil && d.Auth != nil {
			return d.Diag.Middleware(d.Auth.Resolve)(next)
		}
		if d.Diag != nil {
			return d.Diag.Middleware(nil)(next)
		}
		return next
	}
	analyticsOrigin := ""
	if d.analyticsOn() {
		analyticsOrigin = countlyOrigin
	}
	return httpx.Chain(
		mux,
		httperr.WithRequestID(),
		httpx.Recover(d.Log),
		secheaders.Middleware(SecurityHeaders(c, analyticsOrigin)),
		httpx.APICaseGuard(),
		httpx.NoStoreAPI(),
		corsMiddleware(d.Config),
		jsonBodyLimitMiddleware(jsonBodyLimit),
		diags,
		apiRateMiddleware(lim, d.Log),
	)
}

func StartStatusSampler(ctx context.Context, d Deps) func() {
	c := d.cfg()
	hist := newStatusHistory(c.Paths.Data, d.Now)
	cctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		select {
		case <-cctx.Done():
			return
		case <-time.After(15 * time.Second):
		}
		sample := func() {
			st := buildPublicStatus(cctx, d)
			if s, _ := st["status"].(string); s != "" {
				hist.record(s)
			}
		}
		sample()
		t := time.NewTicker(statusSampleInt)
		defer t.Stop()
		for {
			select {
			case <-cctx.Done():
				return
			case <-t.C:
				sample()
			}
		}
	}()
	return func() {
		cancel()
		<-done
	}
}

func NewHTTPServer(addr string, h http.Handler, log *slog.Logger) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
}

func apiRateMiddleware(lim *httperr.SlidingLimiter, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.HasPrefix(r.URL.Path, "/api/v1") {
				if !lim.Allow(w, r, log) {
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

func jsonBodyLimitMiddleware(limit int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ct := strings.ToLower(r.Header.Get("Content-Type"))
			if r.Body != nil && (strings.Contains(ct, "application/json") || ct == "") {
				if !strings.Contains(r.URL.Path, "/chunks/") && !strings.Contains(r.URL.Path, "/parts/") && !strings.HasSuffix(r.URL.Path, "/context") {
					r.Body = http.MaxBytesReader(w, r.Body, limit)
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

func corsMiddleware(cfgFn func() config.Config) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := strings.TrimSpace(r.Header.Get("Origin"))
			if origin == "" {
				next.ServeHTTP(w, r)
				return
			}
			c := config.Config{}
			if cfgFn != nil {
				c = cfgFn()
			}
			allowed := originAllowed(origin, r, c)
			if !allowed {
				if r.Method == http.MethodOptions {
					w.WriteHeader(http.StatusForbidden)
					return
				}
				httperr.WriteError(w, r, nil, httperr.New(http.StatusForbidden, "CORS_DENIED", "CORS origin denied"))
				return
			}
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Set("Access-Control-Allow-Credentials", "true")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key, X-Request-Id, X-Audio-Container, X-Audio-Codec, X-Audio-Content-Encoding, X-Channel-Layout, X-Chunk-Duration-Ms, X-Chunk-Overlap-Ms, X-Monotonic-Offset-Ms, X-Device-Started-At, X-Chunk-Sha256, X-Final-Chunk, X-Import-Part-Sha256, X-Import-Range-Start, X-Import-Range-End, X-Import-Total-Bytes")
			h.Set("Access-Control-Allow-Methods", "GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS")
			h.Add("Vary", "Origin")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func originAllowed(origin string, r *http.Request, c config.Config) bool {
	if origin == "" || origin == "null" {
		return false
	}
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	if strings.EqualFold(u.Host, r.Host) {
		return true
	}
	if pu, perr := url.Parse(c.PublicURL); perr == nil && pu.Scheme != "" && pu.Host != "" {
		if strings.EqualFold(u.Scheme+"://"+u.Host, pu.Scheme+"://"+pu.Host) {
			return true
		}
	}
	if strings.TrimSpace(c.AllowedOrigins) != "" {
		for _, item := range strings.Split(c.AllowedOrigins, ",") {
			if strings.EqualFold(strings.TrimSpace(item), origin) {
				return true
			}
		}
		return false
	}
	switch u.Hostname() {
	case "localhost", "127.0.0.1", "::1":
		return true
	}
	return false
}

func inspectReadiness(ctx context.Context, d Deps) (dbOK, workerOK, sttOK, llmOK, vecOK bool) {
	if d.DB != nil {
		var one int
		if d.DB.R.QueryRowContext(ctx, `SELECT 1`).Scan(&one) == nil {
			dbOK = true
			var state, hb string
			if err := d.DB.R.QueryRowContext(ctx, `SELECT model_state, heartbeat_at FROM worker_heartbeats ORDER BY heartbeat_at DESC LIMIT 1`).Scan(&state, &hb); err == nil {
				if t, terr := timeutil.ParseISO(hb); terr == nil && state == "ready" && time.Since(t) < 20*time.Second {
					workerOK = true
				}
			}
		}
	}
	if d.STTReady != nil {
		sttOK = d.STTReady(ctx)
	}
	if d.AIReady != nil {
		llmOK = d.AIReady(ctx)
	}
	if d.VecReady != nil {
		vecOK = d.VecReady()
	}
	return
}

func buildPublicStatus(ctx context.Context, d Deps) map[string]any {
	storage, worker, sttOK, llmOK, vector := inspectReadiness(ctx, d)
	_ = sttOK
	comp := func(group, name string, ok bool, degradedStatus, okDesc, badDesc string) map[string]string {
		st := degradedStatus
		desc := badDesc
		if ok {
			st = "operational"
			desc = okDesc
		}
		return map[string]string{"group": group, "name": name, "status": st, "description": desc}
	}
	components := []map[string]string{
		{"group": "Core", "name": "Web App & API", "status": "operational", "description": "The web server is responding to requests."},
		comp("Data", "Storage", storage, "unavailable", "The database is responding.", "The database could not be reached."),
		comp("Processing", "Transcription Worker", worker, "degraded", "A ready worker has reported recently.", "A ready worker has not reported recently."),
		comp("AI", "Language Model", llmOK, "degraded", "A language model is configured for use.", "The language model is not ready to accept work."),
		comp("Data", "Semantic Search", vector, "degraded", "The semantic search index is available.", "Semantic search is unavailable."),
	}
	overall := "operational"
	for _, c := range components {
		if c["status"] == "unavailable" {
			overall = "unavailable"
			break
		}
		if c["status"] == "degraded" {
			overall = "degraded"
		}
	}
	note := "One or more monitored services need attention."
	if overall == "operational" {
		note = "All monitored services are operational."
	}
	now := time.Now
	if d.Now != nil {
		now = d.Now
	}
	return map[string]any{
		"product":             "NeoRecall",
		"status":              overall,
		"updatedAt":           timeutil.FormatISO(now().UTC()),
		"refreshAfterSeconds": 60,
		"note":                note,
		"components":          components,
	}
}

type statusEntry struct {
	Time   int64  `json:"time"`
	Status string `json:"status"`
}

type statusHistory struct {
	mu   sync.Mutex
	dir  string
	file string
	now  func() time.Time
}

var statusSeverity = map[string]int{"operational": 0, "degraded": 1, "unavailable": 2}

func newStatusHistory(dataDir string, now func() time.Time) *statusHistory {
	if now == nil {
		now = time.Now
	}
	return &statusHistory{dir: dataDir, file: filepath.Join(dataDir, "public-status-history.json"), now: now}
}

func (h *statusHistory) readLocked() []statusEntry {
	raw, err := os.ReadFile(h.file)
	if err != nil {
		return nil
	}
	var all []statusEntry
	if json.Unmarshal(raw, &all) != nil {
		return nil
	}
	out := make([]statusEntry, 0, len(all))
	for _, it := range all {
		if _, ok := statusSeverity[it.Status]; ok && it.Time > 0 {
			out = append(out, it)
		}
	}
	return out
}

func (h *statusHistory) history() []map[string]any {
	h.mu.Lock()
	entries := h.readLocked()
	h.mu.Unlock()
	byHour := make(map[int64]string, len(entries))
	for _, e := range entries {
		byHour[e.Time] = e.Status
	}
	cur := (h.now().UnixMilli() / 3_600_000) * 3_600_000
	out := make([]map[string]any, statusHours)
	for i := 0; i < statusHours; i++ {
		t := cur - int64(statusHours-1-i)*3_600_000
		var st any
		if v, ok := byHour[t]; ok {
			st = v
		}
		out[i] = map[string]any{
			"time":   timeutil.FormatISO(time.UnixMilli(t).UTC()),
			"status": st,
		}
	}
	return out
}

func (h *statusHistory) record(status string) {
	sev, ok := statusSeverity[status]
	if !ok || h.dir == "" {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	cur := (h.now().UnixMilli() / 3_600_000) * 3_600_000
	cutoff := cur - int64(statusHours)*3_600_000
	kept := []statusEntry{}
	found := false
	for _, e := range h.readLocked() {
		if e.Time > cutoff && e.Time <= cur {
			if e.Time == cur {
				found = true
				if sev > statusSeverity[e.Status] {
					e.Status = status
				}
			}
			kept = append(kept, e)
		}
	}
	if !found {
		kept = append(kept, statusEntry{Time: cur, Status: status})
	}
	_ = os.MkdirAll(h.dir, 0o700)
	b, _ := json.Marshal(kept)
	tmp := fmt.Sprintf("%s.%d.tmp", h.file, os.Getpid())
	if os.WriteFile(tmp, b, 0o600) == nil {
		_ = os.Rename(tmp, h.file)
	}
}

var flutterNoStore = map[string]bool{
	"index.html":                true,
	"flutter_bootstrap.js":      true,
	"flutter_service_worker.js": true,
	"version.json":              true,
}

func setNoStore(h http.Header) {
	h.Set("Cache-Control", "no-store, no-cache, must-revalidate, proxy-revalidate")
	h.Set("Pragma", "no-cache")
	h.Set("Expires", "0")
	h.Set("Surrogate-Control", "no-store")
	h.Set("CDN-Cache-Control", "no-store")
}

func openRooted(dir, rel string) (*os.File, fs.FileInfo, error) {
	if dir == "" {
		return nil, nil, fs.ErrNotExist
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, nil, err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return nil, nil, err
	}
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		f.Close()
		if err == nil {
			err = fs.ErrNotExist
		}
		return nil, nil, err
	}
	return f, st, nil
}

func serveStaticFile(w http.ResponseWriter, r *http.Request, f *os.File, st fs.FileInfo) {
	w.Header().Set("ETag", fmt.Sprintf(`W/"%x-%x"`, st.Size(), st.ModTime().UnixMilli()))
	if w.Header().Get("Cache-Control") == "" {
		w.Header().Set("Cache-Control", "public, max-age=0")
	}
	http.ServeContent(w, r, st.Name(), st.ModTime(), f)
}

func injectHeadScript(html, tag string) string {
	idx := strings.Index(strings.ToLower(html), "</head>")
	if idx < 0 {
		return html
	}
	return html[:idx] + tag + "\n" + html[idx:]
}

func flutterApp(webDir func() string, analytics bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			httpx.Error(w, http.StatusMethodNotAllowed, "Method not allowed")
			return
		}
		dir := webDir()
		rel := strings.TrimPrefix(path.Clean(strings.TrimPrefix(r.URL.Path, "/app")), "/")
		if rel != "" && rel != "." && rel != "index.html" {
			if f, st, err := openRooted(dir, rel); err == nil {
				defer f.Close()
				if flutterNoStore[path.Base(rel)] {
					setNoStore(w.Header())
				}
				serveStaticFile(w, r, f, st)
				return
			}
			// Do not SPA-fallback missing static asset requests that carry extensions.
			if ext := path.Ext(rel); ext != "" {
				httperr.WriteError(w, r, nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Not found"))
				return
			}
		}
		f, _, err := openRooted(dir, "index.html")
		if err != nil {
			httperr.WriteError(w, r, nil, httperr.New(http.StatusServiceUnavailable, "WEB_UI_MISSING",
				"NeoRecall web UI assets are missing. Build flutter_app/build/web or set NEORECALL_WEB_DIR."))
			return
		}
		defer f.Close()
		raw, err := io.ReadAll(f)
		if err != nil {
			httpx.Error(w, http.StatusInternalServerError, "Internal server error")
			return
		}
		html := strings.Replace(string(raw), `<base href="/">`, `<base href="/app/">`, 1)
		if !strings.Contains(html, "/js/cookie-notice.js") {
			html = injectHeadScript(html, `<script defer src="/js/cookie-notice.js"></script>`)
		}
		if analytics {
			html = injectHeadScript(html, `<script defer src="/_neolabs/analytics.js"></script>`)
		}
		setNoStore(w.Header())
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, html)
	})
}

func landingHandler(landingDir func() string, analytics bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			httpx.Error(w, http.StatusNotFound, "Not found")
			return
		}
		dir := landingDir()
		rel := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		switch rel {
		case "", ".":
			rel = "index.html"
		case "status":
			rel = "status.html"
		}
		if rel == "index.html" && analytics {
			if f, _, err := openRooted(dir, rel); err == nil {
				raw, rerr := io.ReadAll(f)
				f.Close()
				if rerr == nil {
					html := injectHeadScript(string(raw), `<script defer src="/_neolabs/analytics.js"></script>`)
					setNoStore(w.Header())
					w.Header().Set("Content-Type", "text/html; charset=utf-8")
					_, _ = io.WriteString(w, html)
					return
				}
			}
		}
		if f, st, err := openRooted(dir, rel); err == nil {
			defer f.Close()
			serveStaticFile(w, r, f, st)
			return
		}
		if !strings.HasSuffix(rel, ".html") {
			if f, st, err := openRooted(dir, rel+".html"); err == nil {
				defer f.Close()
				serveStaticFile(w, r, f, st)
				return
			}
		}
		if !strings.HasPrefix(r.URL.Path, "/api/") && prefersHTML(r) {
			if f, st, err := openRooted(dir, "404.html"); err == nil {
				defer f.Close()
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.Header().Set("Last-Modified", st.ModTime().UTC().Format(time.RFC1123))
				w.WriteHeader(http.StatusNotFound)
				if r.Method != http.MethodHead {
					_, _ = io.Copy(w, f)
				}
				return
			}
		}
		httperr.WriteError(w, r, nil, httperr.New(http.StatusNotFound, "NOT_FOUND", "Not found"))
	})
}

func prefersHTML(r *http.Request) bool {
	accept := r.Header.Get("Accept")
	h := strings.Index(accept, "text/html")
	j := strings.Index(accept, "application/json")
	return h >= 0 && (j < 0 || h < j)
}

const analyticsClientTemplate = `/* Coarse browser analytics: no page content, URLs, identifiers, or error details. */
(function () {
  'use strict';
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1' || navigator.globalPrivacyControl === true) return;
  var config = /* COUNTLY_CONFIG */ null;
  if (!config || !window.fetch) return;
  var originalFetch = window.fetch;
  var area = location.pathname === '/' || location.pathname === '/index.html' ? 'landing' : 'app';

  function event(key, segmentation, count) {
    return { key: key, count: count, segmentation: Object.assign({ area: area }, segmentation) };
  }
  function send(events) {
    if (!events.length) return;
    try {
      var body = new URLSearchParams({ app_key: config.appKey, device_id: 'aggregate-browser', events: JSON.stringify(events) });
      originalFetch.call(window, config.endpoint, {
        method: 'POST', body: body, mode: 'cors', credentials: 'omit',
        referrerPolicy: 'no-referrer', redirect: 'error', keepalive: true,
      }).catch(function () {});
    } catch (_) {}
  }
  send([{ key: '[CLY]_view', count: 1, segmentation: { name: area, view: area === 'landing' ? '/' : '/app', visit: 1 } }]);
  function reportLoad() {
    var start = performance.getEntriesByType('navigation')[0];
    if (!start) return;
    var seconds = start.loadEventEnd / 1000;
    send([event('page-load', { duration: seconds < 1 ? '<1s' : seconds < 3 ? '1-3s' : seconds < 10 ? '3-10s' : '10s+' }, 1)]);
  }
  if (document.readyState === 'complete') reportLoad();
  else window.addEventListener('load', function () { setTimeout(reportLoad, 0); }, { once: true });
})();
`
