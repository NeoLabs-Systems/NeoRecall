package manager

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"

	"context"
	"fmt"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestWaitForServerVersion(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"version":"2.0.0"}`) }))
	defer srv.Close()
	_, portText, err := net.SplitHostPort(srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	m := &Manager{}
	if err := m.waitForServerVersion(context.Background(), port, "2.0.0", time.Second); err != nil {
		t.Fatal(err)
	}
	if err := m.waitForServerVersion(context.Background(), port, "3.0.0", 300*time.Millisecond); err == nil {
		t.Fatal("accepted wrong server version")
	}
}

func TestIncompleteWebBundleKeepsExistingApp(t *testing.T) {
	var bundle bytes.Buffer
	gz := gzip.NewWriter(&bundle)
	tw := tar.NewWriter(gz)
	if err := tw.WriteHeader(&tar.Header{Name: "unrelated.txt", Mode: 0o644, Size: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(bundle.Bytes()) }))
	defer srv.Close()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(cfg.Paths.RuntimeDir, "app", "flutter_app", "build", "web"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldIndex := filepath.Join(cfg.Paths.RuntimeDir, "app", "flutter_app", "build", "web", "index.html")
	if err := os.WriteFile(oldIndex, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := &Manager{HTTP: srv.Client()}
	rel := githubRelease{Assets: []githubAsset{{Name: "neorecall-web-test.tar.gz", BrowserDownloadURL: srv.URL}}}
	if _, err := m.installWebBundle(context.Background(), cfg, rel); err == nil {
		t.Fatal("accepted incomplete bundle")
	}
	if data, err := os.ReadFile(oldIndex); err != nil || string(data) != "old" {
		t.Fatalf("old web bundle = %q, %v", data, err)
	}
}
