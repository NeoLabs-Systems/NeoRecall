package httpserver_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/app"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
)

func TestAppWiringHealthMetaStatusCSPAndSPA(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	webDir := t.TempDir()
	landingDir := t.TempDir()

	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte(`<!doctype html><html><head><base href="/"></head><body>SPA</body></html>`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(webDir, "main.dart.js"), []byte("app"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(landingDir, "index.html"), []byte(`<!doctype html><html><head></head><body>LANDING</body></html>`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(landingDir, "404.html"), []byte(`<h1>Custom 404</h1>`), 0o644); err != nil {
		t.Fatal(err)
	}

	getenv := func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "NEORECALL_WEB_DIR":
			return webDir
		case "NEORECALL_LANDING_DIR":
			return landingDir
		case "ANALYTICS_ENABLED":
			return "false"
		}
		return ""
	}
	cfg, err := config.Load(getenv, home, home)
	if err != nil {
		t.Fatal(err)
	}
	cfg.WebDir = webDir
	cfg.Landing = landingDir

	a, err := app.Open(ctx, app.Options{
		StaticConfig: &cfg,
		Getenv:       getenv,
		Logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		Version:      "0.2.0-test",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()

	// 1. /health + security headers + CORS
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("Origin", "http://localhost:3000")
	rec := httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/health=%d %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Content-Security-Policy") == "" || rec.Header().Get("Access-Control-Allow-Origin") != "http://localhost:3000" {
		t.Fatalf("missing security/CORS headers: csp=%q acao=%q", rec.Header().Get("Content-Security-Policy"), rec.Header().Get("Access-Control-Allow-Origin"))
	}

	// 2. /ready (degraded when no worker/AI)
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("/ready=%d expected 503 when not ready", rec.Code)
	}

	// 3. /api/public/status
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/public/status", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/public/status=%d", rec.Code)
	}
	var pub struct {
		Product string           `json:"product"`
		History []map[string]any `json:"history"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &pub); err != nil || pub.Product != "NeoRecall" || len(pub.History) != 48 {
		t.Fatalf("unexpected public status: %+v err=%v", pub, err)
	}

	// 4. Register user and call /api/v1/meta & /api/v1/sources
	regBody := `{"username":"alice","password":"StrongPassword!1"}`
	req = httptest.NewRequest(http.MethodPost, "/api/v1/auth/register", strings.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register=%d %s", rec.Code, rec.Body.String())
	}
	var regRes struct {
		Session struct {
			Token string `json:"token"`
		} `json:"session"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &regRes)
	if regRes.Session.Token == "" {
		t.Fatalf("expected token from register: %s", rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/meta", nil)
	req.Header.Set("Authorization", "Bearer "+regRes.Session.Token)
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"recordingContext":true`) {
		t.Fatalf("/api/v1/meta=%d %s", rec.Code, rec.Body.String())
	}

	// 5. Legacy /admin/api -> 410 and /admin -> 302
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/admin/api/stats", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("/admin/api/stats=%d expected 410", rec.Code)
	}
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/admin", nil))
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/app/" {
		t.Fatalf("/admin=%d loc=%q", rec.Code, rec.Header().Get("Location"))
	}

	// 6. SPA base href rewrite + landing + traversal refusal
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/app/settings", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `<base href="/app/">`) {
		t.Fatalf("/app/settings=%d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/app/main.dart.js", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Header().Get("Cache-Control"), "no-store") {
		t.Fatalf("main.dart.js: status=%d headers=%v", rec.Code, rec.Header())
	}
	rec = httptest.NewRecorder()
	a.Handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "LANDING") {
		t.Fatalf("/ landing=%d %s", rec.Code, rec.Body.String())
	}
}
