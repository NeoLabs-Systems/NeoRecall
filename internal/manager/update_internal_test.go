package manager

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"io"
	"os/exec"
	"runtime"
	"strings"
	"syscall"

	"archive/tar"
	"bytes"
	"compress/gzip"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/cli/service"
	"github.com/NeoLabs-Systems/neorecall/internal/runtimebundle"
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

func TestStageRuntimeVerifiesSignatureAndDigest(t *testing.T) {
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
	stage := t.TempDir()
	for name, data := range map[string]string{filepath.Join("app", "bin", runtimeBinaryName()): "binary", filepath.Join("app", "flutter_app", "build", "web", "index.html"): "web"} {
		p := filepath.Join(stage, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(data), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	archive := filepath.Join(t.TempDir(), "runtime.zip")
	if err := release.CreateZip(stage, archive); err != nil {
		t.Fatal(err)
	}
	sum, size, err := release.FileDigest(archive)
	if err != nil {
		t.Fatal(err)
	}
	archiveData, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	platform, arch := runtime.GOOS, runtime.GOARCH
	if platform == "darwin" {
		platform = "macos"
	}
	if arch == "amd64" {
		arch = "x64"
	}
	if platform == "windows" && arch != "x64" {
		t.Skip("no supported Windows runtime")
	}
	manifest, err := json.Marshal(release.RuntimeManifest{SchemaVersion: 1, Version: "2.0.0", Artifacts: []release.Artifact{{Platform: platform, Architecture: arch, AssetName: "runtime.zip", SizeBytes: size, SHA256: sum}}})
	if err != nil {
		t.Fatal(err)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	signature, err := release.Sign(manifest, base64.StdEncoding.EncodeToString(privateDER))
	if err != nil {
		t.Fatal(err)
	}
	signedBytes := []byte(signature)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/manifest":
			_, _ = w.Write(manifest)
		case "/sig":
			_, _ = w.Write(signedBytes)
		case "/archive":
			_, _ = w.Write(archiveData)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	name := runtimebundle.ManifestPrefix + "2.0.0.json"
	rel := githubRelease{TagName: "v2.0.0", Assets: []githubAsset{{Name: name, BrowserDownloadURL: srv.URL + "/manifest"}, {Name: name + ".sig", BrowserDownloadURL: srv.URL + "/sig"}, {Name: "runtime.zip", BrowserDownloadURL: srv.URL + "/archive"}}}
	client := &release.Client{HTTP: srv.Client(), AllowHTTP: true}
	key := base64.StdEncoding.EncodeToString(pub)
	signedBytes = []byte("invalid")
	if err := stageRuntimeFromManifest(context.Background(), cfg, rel, "2.0.0", key, client); err == nil {
		t.Fatal("accepted invalid signature")
	}
	signedBytes = []byte(signature)
	archiveData[0] ^= 1
	if err := stageRuntimeFromManifest(context.Background(), cfg, rel, "2.0.0", key, client); err == nil {
		t.Fatal("accepted invalid archive digest")
	}
	archiveData[0] ^= 1
	if err := stageRuntimeFromManifest(context.Background(), cfg, rel, "2.0.0", key, client); err != nil {
		t.Fatal(err)
	}
	if err := runtimeStore(cfg).Validate("2.0.0"); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeMigrationAndRollbackSnapshot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("NEORECALL_HOME", home)
	cfg, err := config.Load(os.Getenv, home, home)
	if err != nil {
		t.Fatal(err)
	}
	store := runtimeStore(cfg)
	for _, version := range []string{"1.0.0", "2.0.0"} {
		dir, err := store.RuntimeDir(version)
		if err != nil {
			t.Fatal(err)
		}
		for _, name := range store.RequiredFiles {
			p := filepath.Join(dir, name)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte(version), 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := store.Activate("1.0.0"); err != nil {
		t.Fatal(err)
	}
	markerPath := filepath.Join(store.Root, "current.json")
	marker, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatal(err)
	}
	servicePath := filepath.Join(home, "service")
	if err := os.WriteFile(servicePath, []byte("old service"), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot := serviceSnapshot{path: servicePath, content: []byte("old service")}
	if err := store.Activate("2.0.0"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(servicePath, []byte("new service"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := restoreRuntimeSnapshot(markerPath, marker, snapshot); err != nil {
		t.Fatal(err)
	}
	active, err := store.Current()
	if err != nil || active.Version != "1.0.0" {
		t.Fatalf("current: %+v, %v", active, err)
	}
	data, err := os.ReadFile(servicePath)
	if err != nil || string(data) != "old service" {
		t.Fatalf("service: %q, %v", data, err)
	}
	m := &Manager{Getenv: os.Getenv, UserHome: home, Cwd: home}
	resolved, err := m.loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	dir, _ := store.RuntimeDir("1.0.0")
	if resolved.AppDir != filepath.Join(dir, "app") {
		t.Fatalf("resolved app directory: %s", resolved.AppDir)
	}
	sm, err := m.serviceManager(resolved)
	if err != nil {
		t.Fatal(err)
	}
	if sm.Spec.Program != filepath.Join(dir, "app", "bin", runtimeBinaryName()) {
		t.Fatalf("service executable: %s", sm.Spec.Program)
	}
	if runtime.GOOS == "darwin" && sm.Platform != "macos" {
		t.Fatalf("service platform: %s", sm.Platform)
	}
}

func TestSignedRuntimeUpdateStartsAndRollsBackEndToEnd(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fallback process test is Unix-specific")
	}
	home, work, dist := t.TempDir(), t.TempDir(), t.TempDir()
	getenv := func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}
	cfg, err := config.Load(getenv, home, work)
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.Paths.Ensure(); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	cfg.Port = port
	if err := os.WriteFile(cfg.Paths.EnvFile, []byte(fmt.Sprintf("NEORECALL_PORT=%d\nNEORECALL_RELEASE_CHANNEL=beta\n", port)), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NEORECALL_PORT", strconv.Itoa(port))
	oldBin, nextBin, brokenBin := filepath.Join(work, "old"), filepath.Join(work, "next"), filepath.Join(work, "broken")
	for _, target := range []struct{ path, version string }{{oldBin, "1.0.0"}, {nextBin, "2.0.0"}} {
		cmd := exec.Command("go", "build", "-ldflags", "-X github.com/NeoLabs-Systems/neorecall/internal/config.Version="+target.version, "-o", target.path, "../../cmd/neorecall")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("build %s: %v\n%s", target.version, err, out)
		}
	}
	if err := os.WriteFile(brokenBin, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	privateKey := base64.StdEncoding.EncodeToString(privateDER)
	publish := func(version, binary string) {
		stage := t.TempDir()
		app := filepath.Join(stage, "app")
		for name, body := range map[string][]byte{filepath.Join("bin", runtimeBinaryName()): mustRead(t, binary), filepath.Join("flutter_app", "build", "web", "index.html"): []byte("<html></html>")} {
			p := filepath.Join(app, name)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, body, 0o755); err != nil {
				t.Fatal(err)
			}
		}
		platform, arch := runtime.GOOS, runtime.GOARCH
		if platform == "darwin" {
			platform = "macos"
		}
		if arch == "amd64" {
			arch = "x64"
		}
		archive := filepath.Join(dist, fmt.Sprintf("neorecall-runtime-%s-%s-%s.zip", platform, arch, version))
		if err := release.CreateZip(stage, archive); err != nil {
			t.Fatal(err)
		}
		sum, size, err := release.FileDigest(archive)
		if err != nil {
			t.Fatal(err)
		}
		manifest, err := release.NewRuntimeManifest(1, version, []release.Artifact{{Platform: platform, Architecture: arch, AssetName: filepath.Base(archive), SHA256: sum, SizeBytes: size}}, release.Targets{platform: {arch}})
		if err != nil {
			t.Fatal(err)
		}
		data, err := release.Serialize(manifest)
		if err != nil {
			t.Fatal(err)
		}
		sig, err := release.Sign(data, privateKey)
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(dist, runtimebundle.ManifestPrefix+version+".json"), data, 0o644)
		os.WriteFile(filepath.Join(dist, runtimebundle.ManifestPrefix+version+".json.sig"), []byte(sig), 0o644)
	}
	publish("1.0.0", oldBin)
	publish("2.0.0", nextBin)
	publish("3.0.0", brokenBin)
	latest := "1.0.0"
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/releases") {
			platform, arch := runtime.GOOS, runtime.GOARCH
			if platform == "darwin" {
				platform = "macos"
			}
			if arch == "amd64" {
				arch = "x64"
			}
			names := []string{runtimebundle.ManifestPrefix + latest + ".json", runtimebundle.ManifestPrefix + latest + ".json.sig", fmt.Sprintf("neorecall-runtime-%s-%s-%s.zip", platform, arch, latest)}
			assets := make([]map[string]any, 0, len(names))
			for _, n := range names {
				assets = append(assets, map[string]any{"name": n, "browser_download_url": apiURL(r, n)})
			}
			json.NewEncoder(w).Encode([]any{map[string]any{"tag_name": "v" + latest, "prerelease": true, "assets": assets}})
			return
		}
		http.ServeFile(w, r, filepath.Join(dist, filepath.Base(r.URL.Path)))
	}))
	defer api.Close()
	m := &Manager{Getenv: getenv, UserHome: home, Cwd: work, Version: "1.0.0", HTTP: api.Client(), ReleaseAPIBase: api.URL, ReleaseClientFactory: func() *release.Client { return &release.Client{HTTP: api.Client()} }, RuntimePublicKey: base64.StdEncoding.EncodeToString(pub), RuntimeStartupTimeout: 5 * time.Second, RuntimeRollbackTimeout: 10 * time.Second, Out: io.Discard, Err: io.Discard, UI: cli.NewUI(true)}
	m.ReleaseClientFactory = func() *release.Client { return &release.Client{HTTP: api.Client()} }
	// First boot the currently installed binary from the versioned runtime store.
	platform, arch := runtime.GOOS, runtime.GOARCH
	if platform == "darwin" {
		platform = "macos"
	}
	if arch == "amd64" {
		arch = "x64"
	}
	if err := runtimeStore(cfg).InstallArchive("1.0.0", filepath.Join(dist, fmt.Sprintf("neorecall-runtime-%s-%s-1.0.0.zip", platform, arch))); err != nil {
		t.Fatal(err)
	}
	if err := runtimeStore(cfg).Activate("1.0.0"); err != nil {
		t.Fatal(err)
	}
	sm, err := m.serviceManager(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := sm.StartFallback(); err != nil {
		t.Fatal(err)
	}
	waitCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := m.waitForServerVersion(waitCtx, port, "1.0.0", 40*time.Second); err != nil {
		t.Fatalf("old server: %v", err)
	}
	stop := func(config.Config, *service.Manager) {
		raw, _ := os.ReadFile(cfg.Paths.PIDFile)
		pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
		if pid > 0 {
			if p, e := os.FindProcess(pid); e == nil {
				_ = p.Signal(syscall.SIGTERM)
			}
			deadline := time.Now().Add(10 * time.Second)
			for time.Now().Before(deadline) && cli.PortOpen(port) {
				time.Sleep(100 * time.Millisecond)
			}
		}
		_ = os.Remove(cfg.Paths.PIDFile)
	}
	m.StopManagedService = stop
	latest = "2.0.0"
	rolled, err := m.updateSignedRuntime(waitCtx, cfg, mustLocalRelease(t, api, dist, latest), "1.0.0", latest)
	if err != nil || rolled {
		t.Fatalf("successful update: rolled=%v err=%v", rolled, err)
	}
	if current, e := runtimeStore(cfg).Current(); e != nil || current.Version != "2.0.0" {
		t.Fatalf("active after success: %+v %v", current, e)
	}
	if err := m.waitForServerVersion(waitCtx, port, "2.0.0", 30*time.Second); err != nil {
		logs, _ := os.ReadFile(filepath.Join(cfg.Paths.Logs, "neorecall.error.log"))
		t.Fatalf("%v\n%s", err, logs)
	}
	latest = "3.0.0"
	rolled, err = m.updateSignedRuntime(waitCtx, cfg, mustLocalRelease(t, api, dist, latest), "2.0.0", latest)
	if err == nil || !rolled {
		t.Fatalf("expected rollback, rolled=%v err=%v", rolled, err)
	}
	if current, e := runtimeStore(cfg).Current(); e != nil || current.Version != "2.0.0" {
		t.Fatalf("active after rollback: %+v %v", current, e)
	}
	if err := m.waitForServerVersion(waitCtx, port, "2.0.0", 30*time.Second); err != nil {
		t.Fatal(err)
	}
	stop(cfg, sm)

	// Exercise the user-facing migration path from a running Node.js install to Go.
	legacyHome, legacyWork, legacyPort := t.TempDir(), t.TempDir(), freeLocalPort(t)
	legacyBinDir := filepath.Join(legacyHome, "npm-bin")
	legacyApp := filepath.Join(legacyHome, "legacy-app")
	if err := os.MkdirAll(filepath.Join(legacyApp, "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	legacyServer := filepath.Join(legacyApp, "server", "index.js")
	if err := os.WriteFile(legacyServer, []byte(`const http=require('http');http.createServer((req,res)=>{res.setHeader('content-type','application/json');res.end(JSON.stringify({version:'1.0.0'}));}).listen(Number(process.env.NEORECALL_PORT),'127.0.0.1');`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(legacyApp, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacyApp, "bin", "neorecall.js"), []byte("// legacy CLI"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(legacyBinDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(legacyApp, "bin", "neorecall.js"), filepath.Join(legacyBinDir, "neorecall")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", legacyHome)
	t.Setenv("NEORECALL_HOME", legacyHome)
	t.Setenv("NEORECALL_PORT", strconv.Itoa(legacyPort))
	t.Setenv("NEORECALL_RELEASE_CHANNEL", "beta")
	t.Setenv("PATH", legacyBinDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	legacyCfg, err := config.Load(os.Getenv, legacyHome, legacyWork)
	if err != nil {
		t.Fatal(err)
	}
	legacyCfg.Port = legacyPort
	if err := legacyCfg.Paths.Ensure(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyCfg.Paths.EnvFile, []byte(fmt.Sprintf("NEORECALL_PORT=%d\nNEORECALL_RELEASE_CHANNEL=beta\nNEORECALL_APP_DIR=%s\n", legacyPort, legacyApp)), 0o600); err != nil {
		t.Fatal(err)
	}
	legacyCmd := exec.Command("node", legacyServer)
	legacyCmd.Env = append(os.Environ(), "NEORECALL_PORT="+strconv.Itoa(legacyPort))
	if err := legacyCmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if legacyCmd.Process != nil {
			_ = legacyCmd.Process.Kill()
			_, _ = legacyCmd.Process.Wait()
		}
	}()
	legacyCtx, legacyCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer legacyCancel()
	legacyManager := &Manager{Getenv: os.Getenv, UserHome: legacyHome, Cwd: legacyWork, Version: "1.0.0", HTTP: api.Client(), ReleaseAPIBase: api.URL, RuntimePublicKey: base64.StdEncoding.EncodeToString(pub), RuntimeStartupTimeout: 5 * time.Second, RuntimeRollbackTimeout: 10 * time.Second, Out: io.Discard, Err: io.Discard, UI: cli.NewUI(true)}
	if err := legacyManager.waitForServerVersion(legacyCtx, legacyPort, "1.0.0", 10*time.Second); err != nil {
		t.Fatalf("legacy Node server: %v", err)
	}
	if err := legacyManager.cmdStop(legacyCtx, nil); err != nil {
		t.Fatalf("stop legacy Node server: %v", err)
	}
	if cli.PortOpen(legacyPort) {
		t.Fatal("stop reported success while legacy Node server still owns its port")
	}
	latest = "2.0.0"
	if err := legacyManager.cmdUpdate(legacyCtx, nil); err != nil {
		t.Fatalf("update Node installation to Go: %v", err)
	}
	if current, e := runtimeStore(legacyCfg).Current(); e != nil || current.Version != "2.0.0" {
		t.Fatalf("legacy migration active runtime: %+v %v", current, e)
	}
	if err := legacyManager.waitForServerVersion(legacyCtx, legacyPort, "2.0.0", 30*time.Second); err != nil {
		t.Fatalf("Go server after Node migration: %v", err)
	}
	legacyManager.stopRunningProcesses(legacyCfg, nil)
}

func freeLocalPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func apiURL(r *http.Request, name string) string { return "https://" + r.Host + "/assets/" + name }
func mustLocalRelease(t *testing.T, api *httptest.Server, dist, version string) githubRelease {
	t.Helper()
	names := []string{runtimebundle.ManifestPrefix + version + ".json", runtimebundle.ManifestPrefix + version + ".json.sig"}
	platform, arch := runtime.GOOS, runtime.GOARCH
	if platform == "darwin" {
		platform = "macos"
	}
	if arch == "amd64" {
		arch = "x64"
	}
	names = append(names, fmt.Sprintf("neorecall-runtime-%s-%s-%s.zip", platform, arch, version))
	assets := make([]githubAsset, 0, len(names))
	for _, name := range names {
		assets = append(assets, githubAsset{Name: name, BrowserDownloadURL: api.URL + "/assets/" + name})
	}
	return githubRelease{TagName: "v" + version, Prerelease: true, Assets: assets}
}

func TestUpdateRefusesUnknownArgumentsBeforeDoingAnything(t *testing.T) {
	// A zero Manager would panic if the command got past argument checking.
	for _, args := range [][]string{{"--dry-run"}, {"--chek"}, {"nightly"}, {"beta", "stable"}} {
		err := (&Manager{}).cmdUpdate(context.Background(), args)
		if err == nil || !strings.HasPrefix(err.Error(), "usage:") {
			t.Fatalf("%v: %v", args, err)
		}
	}
}

func TestOnlyAGoCheckoutSkipsTheRuntime(t *testing.T) {
	dir := t.TempDir()
	if goSourceCheckout(dir) {
		t.Fatal("a plain directory is not a checkout")
	}
	if err := os.Mkdir(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if goSourceCheckout(dir) {
		t.Fatal("a Node.js checkout still needs the runtime")
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !goSourceCheckout(dir) {
		t.Fatal("a Go checkout runs from its tree")
	}
}
