package manager

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"github.com/NeoLabs-Systems/neolabs-go/cli/envfile"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/cli/service"
	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/models"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

const githubRepo = "NeoLabs-Systems/NeoRecall"

type LegacyJSState struct {
	HasDB          bool   `json:"hasDb"`
	MigratedMarker bool   `json:"migratedMarker"`
	LegacyPlist    bool   `json:"legacyPlist"`
	LegacySystemd  bool   `json:"legacySystemd"`
	LegacyNPMBin   string `json:"legacyNpmBin,omitempty"`
	NeedsMigration bool   `json:"needsMigration"`
}

type serviceSnapshot struct {
	path    string
	content []byte
}

func markerPath(cfg config.Config) string {
	return filepath.Join(cfg.Paths.Data, ".go-migrated")
}

func legacyServicePaths(userHome string) (plistPath, systemdPath string) {
	plistPath = filepath.Join(userHome, "Library", "LaunchAgents", config.DefaultServiceLabel+".plist")
	systemdPath = filepath.Join(userHome, ".config", "systemd", "user", "neorecall.service")
	return plistPath, systemdPath
}

func containsNodeServerRef(data []byte) bool {
	s := strings.ToLower(string(data))
	return strings.Contains(s, "server/index.js") || strings.Contains(s, "/node<") || strings.Contains(s, "execstart=/usr/bin/node") || strings.Contains(s, "/bin/node ")
}

func findLegacyNPMSymlink(pathEnv string) string {
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" {
			continue
		}
		cand := filepath.Join(dir, "neorecall")
		target, err := os.Readlink(cand)
		if err != nil {
			continue
		}
		if strings.HasSuffix(filepath.ToSlash(target), "bin/neorecall.js") {
			return cand
		}
	}
	return ""
}

func InspectLegacyJS(cfg config.Config, userHome string, getenv func(string) string) LegacyJSState {
	var st LegacyJSState
	if _, err := os.Stat(cfg.Paths.Database); err == nil {
		st.HasDB = true
	}
	if _, err := os.Stat(markerPath(cfg)); err == nil {
		st.MigratedMarker = true
	}
	plistPath, unitPath := legacyServicePaths(userHome)
	if runtime.GOOS == "darwin" {
		if b, err := os.ReadFile(plistPath); err == nil && containsNodeServerRef(b) {
			st.LegacyPlist = true
		}
	}
	if runtime.GOOS == "linux" {
		if b, err := os.ReadFile(unitPath); err == nil && containsNodeServerRef(b) {
			st.LegacySystemd = true
		}
	}
	if getenv != nil {
		st.LegacyNPMBin = findLegacyNPMSymlink(getenv("PATH"))
	}
	st.NeedsMigration = st.LegacyPlist || st.LegacySystemd || st.LegacyNPMBin != "" || (st.HasDB && !st.MigratedMarker)
	return st
}

func (m *Manager) snapshotService(cfg config.Config) serviceSnapshot {
	plistPath, unitPath := legacyServicePaths(m.UserHome)
	var p string
	switch runtime.GOOS {
	case "darwin":
		p = plistPath
	case "linux":
		p = unitPath
	}
	if p == "" {
		return serviceSnapshot{}
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return serviceSnapshot{path: p}
	}
	return serviceSnapshot{path: p, content: b}
}

func restoreServiceSnapshot(s serviceSnapshot, sm *service.Manager) {
	if s.path == "" || len(s.content) == 0 {
		return
	}
	_ = os.WriteFile(s.path, s.content, 0o644)
	if sm != nil {
		_ = sm.Launch()
	}
}

func (m *Manager) stopRunningProcesses(cfg config.Config, sm *service.Manager) {
	if sm != nil {
		sm.Stop()
	}
	if b, err := os.ReadFile(cfg.Paths.PIDFile); err == nil {
		if pid, perr := strconv.Atoi(strings.TrimSpace(string(b))); perr == nil && pid > 0 && pid != os.Getpid() {
			if p, ferr := os.FindProcess(pid); ferr == nil {
				_ = p.Signal(syscall.SIGTERM)
				deadline := time.Now().Add(8 * time.Second)
				for time.Now().Before(deadline) {
					if err := p.Signal(syscall.Signal(0)); err != nil {
						break
					}
					time.Sleep(150 * time.Millisecond)
				}
			}
		}
		_ = os.Remove(cfg.Paths.PIDFile)
	}

	port := cfg.Port
	if port <= 0 {
		port = defaultPort
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && cli.PortOpen(port) {
		// If a legacy detached Node process still holds the port, signal it politely.
		terminateLegacyPortOwner(port, syscall.SIGTERM)
		time.Sleep(250 * time.Millisecond)
	}
	if cli.PortOpen(port) {
		terminateLegacyPortOwner(port, syscall.SIGKILL)
		time.Sleep(250 * time.Millisecond)
	}
	terminateProcessesHoldingDB(cfg.Paths.Database)
}

func isNeoRecallProcessCmd(cmdLine string) bool {
	s := strings.ToLower(cmdLine)
	return strings.Contains(s, "neorecall") ||
		strings.Contains(s, "server/index.js") ||
		strings.Contains(s, "server/workers") ||
		strings.Contains(s, "inference_host")
}

func terminateLegacyPortOwner(port int, sig syscall.Signal) {
	if runtime.GOOS == "windows" {
		return
	}
	out, err := exec.Command("lsof", "-ti", fmt.Sprintf(":%d", port)).Output()
	if err != nil {
		return
	}
	for _, field := range strings.Fields(string(out)) {
		pid, perr := strconv.Atoi(field)
		if perr != nil || pid <= 0 || pid == os.Getpid() {
			continue
		}
		cmdOut, cerr := exec.Command("ps", "-p", field, "-o", "command=").Output()
		if cerr != nil {
			continue
		}
		if isNeoRecallProcessCmd(string(cmdOut)) {
			if p, ferr := os.FindProcess(pid); ferr == nil {
				_ = p.Signal(sig)
			}
		}
	}
}

func terminateProcessesHoldingDB(dbPath string) {
	if runtime.GOOS == "windows" || dbPath == "" {
		return
	}
	var targets []string
	for _, p := range []string{dbPath, dbPath + "-wal", dbPath + "-shm"} {
		if _, err := os.Stat(p); err == nil {
			targets = append(targets, p)
		}
	}
	if len(targets) == 0 {
		return
	}
	out, err := exec.Command("lsof", append([]string{"-t"}, targets...)...).Output()
	if err != nil {
		return
	}
	seen := map[int]bool{}
	var targetsProc []*os.Process
	for _, field := range strings.Fields(string(out)) {
		pid, perr := strconv.Atoi(field)
		if perr != nil || pid <= 0 || pid == os.Getpid() || seen[pid] {
			continue
		}
		seen[pid] = true
		cmdOut, cerr := exec.Command("ps", "-p", field, "-o", "command=").Output()
		if cerr != nil {
			continue
		}
		if isNeoRecallProcessCmd(string(cmdOut)) {
			if p, ferr := os.FindProcess(pid); ferr == nil {
				_ = p.Signal(syscall.SIGTERM)
				targetsProc = append(targetsProc, p)
			}
		}
	}
	if len(targetsProc) == 0 {
		return
	}
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		alive := false
		for _, p := range targetsProc {
			if p.Signal(syscall.Signal(0)) == nil {
				alive = true
				break
			}
		}
		if !alive {
			return
		}
		time.Sleep(150 * time.Millisecond)
	}
	for _, p := range targetsProc {
		if p.Signal(syscall.Signal(0)) == nil {
			_ = p.Signal(syscall.SIGKILL)
		}
	}
	time.Sleep(250 * time.Millisecond)
}

func (m *Manager) migrateLegacyJSState(ctx context.Context, cfg config.Config, st LegacyJSState) (backupKey string, err error) {
	if st.LegacyNPMBin != "" {
		if rerr := os.Remove(st.LegacyNPMBin); rerr == nil {
			m.UI.OK("Removed legacy Node.js CLI symlink " + st.LegacyNPMBin)
		}
	}

	// Clear stale NEORECALL_APP_DIR from .env if it points to a missing directory
	// or a legacy Node.js checkout so Go resolves or installs the standalone web bundle.
	if vals, lerr := envfile.Load(cfg.Paths.EnvFile); lerr == nil {
		if appDir := strings.TrimSpace(vals["NEORECALL_APP_DIR"]); appDir != "" {
			_, hasWeb := os.Stat(filepath.Join(appDir, "flutter_app", "build", "web", "index.html"))
			_, hasLegacyServer := os.Stat(filepath.Join(appDir, "server", "index.js"))
			_, hasLegacyBin := os.Stat(filepath.Join(appDir, "bin", "neorecall.js"))
			if hasWeb != nil || hasLegacyServer == nil || hasLegacyBin == nil {
				_, _ = envfile.Remove(cfg.Paths.EnvFile, "NEORECALL_APP_DIR")
				_ = os.Unsetenv("NEORECALL_APP_DIR")
			}
		}
	}

	if _, serr := os.Stat(cfg.Paths.Database); serr == nil {
		if converted, derr := schema.EnsurePlaintextLegacyDB(ctx, cfg.Paths.Database, cfg.Paths.SecretKey, cfg.AppDir, cfg.Paths.Home); derr != nil {
			return "", derr
		} else if converted {
			m.UI.OK("Unlocked encrypted legacy NeoRecall database with secret.key")
		}
	}

	if _, serr := os.Stat(cfg.Paths.Database); serr == nil && !st.MigratedMarker {
		if rerr := m.UI.Step("Backing up existing NeoRecall database before upgrade", "Saved pre-upgrade backup", func() error {
			db, oerr := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
			if oerr != nil {
				return oerr
			}
			defer db.Close()
			keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
			bSvc := &backup.Service{DB: db, Cfg: func() config.Config { return cfg }, MasterKey: keyFn}
			art, cerr := bSvc.Create(ctx)
			if cerr != nil {
				return cerr
			}
			backupKey = art.Key
			return nil
		}); rerr != nil {
			return "", rerr
		}
	}

	if pruned, perr := models.PruneRetired(cfg.AppDir, cfg.Paths.Models); perr == nil && len(pruned) > 0 {
		m.UI.OK(fmt.Sprintf("Removed %d retired Node-era model artifact(s)", len(pruned)))
	}
	return backupKey, nil
}

func WriteMigratedMarker(cfg config.Config, ver, backupKey, note string) error {
	if err := os.MkdirAll(filepath.Dir(markerPath(cfg)), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(map[string]any{
		"migratedAt": timeutil.NowISO(),
		"version":    ver,
		"backupKey":  backupKey,
		"note":       note,
	}, "", "  ")
	return envfile.WriteAtomic(markerPath(cfg), append(b, '\n'), 0o600)
}

type githubAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
	Digest             string `json:"digest"`
	Size               int64  `json:"size"`
}

type githubRelease struct {
	TagName    string        `json:"tag_name"`
	Draft      bool          `json:"draft"`
	Prerelease bool          `json:"prerelease"`
	Assets     []githubAsset `json:"assets"`
}

var releaseSemverRe = regexp.MustCompile(`^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$`)

func fetchLatestRelease(ctx context.Context, client *http.Client, channel string) (githubRelease, error) {
	return fetchLatestReleaseFrom(ctx, client, channel, "https://api.github.com")
}

func fetchLatestReleaseFrom(ctx context.Context, client *http.Client, channel, apiBase string) (githubRelease, error) {
	if client == nil {
		client = &http.Client{Timeout: 60 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/repos/%s/releases?per_page=50", strings.TrimRight(apiBase, "/"), githubRepo), nil)
	if err != nil {
		return githubRelease{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := client.Do(req)
	if err != nil {
		return githubRelease{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return githubRelease{}, fmt.Errorf("GitHub releases lookup returned HTTP %d", resp.StatusCode)
	}
	var all []githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&all); err != nil {
		return githubRelease{}, err
	}
	var best *githubRelease
	for i := range all {
		rel := &all[i]
		if rel.Draft {
			continue
		}
		if channel != "beta" && rel.Prerelease {
			continue
		}
		if !releaseSemverRe.MatchString(rel.TagName) {
			continue
		}
		if best == nil || release.CompareVersions(strings.TrimPrefix(rel.TagName, "v"), strings.TrimPrefix(best.TagName, "v")) > 0 {
			best = rel
		}
	}
	if best == nil {
		return githubRelease{}, fmt.Errorf("no %s release published on %s yet", channel, githubRepo)
	}
	return *best, nil
}

func downloadVerifiedAsset(ctx context.Context, client *http.Client, asset githubAsset, dstPath string, mode os.FileMode) error {
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Minute}
	}
	if err := os.MkdirAll(filepath.Dir(dstPath), 0o700); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.BrowserDownloadURL, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s returned HTTP %d", asset.Name, resp.StatusCode)
	}
	tmp := dstPath + ".downloading"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(f, h), resp.Body); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if strings.HasPrefix(asset.Digest, "sha256:") {
		want := strings.TrimPrefix(asset.Digest, "sha256:")
		got := hex.EncodeToString(h.Sum(nil))
		if !strings.EqualFold(want, got) {
			_ = os.Remove(tmp)
			return fmt.Errorf("checksum mismatch for %s", asset.Name)
		}
	}
	return os.Rename(tmp, dstPath)
}

func ExtractTarGZSafe(archivePath, dstDir string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	absDst, err := filepath.Abs(dstDir)
	if err != nil {
		return err
	}
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		rel := filepath.Clean(filepath.FromSlash(strings.TrimPrefix(hdr.Name, "./")))
		if rel == "." || rel == "" || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
			return fmt.Errorf("unsafe archive entry path: %q", hdr.Name)
		}
		target := filepath.Join(absDst, rel)
		if !strings.HasPrefix(target, absDst+string(filepath.Separator)) && target != absDst {
			return fmt.Errorf("archive entry escapes destination: %q", hdr.Name)
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			of, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
			if err != nil {
				return err
			}
			if _, err := io.Copy(of, tr); err != nil {
				_ = of.Close()
				return err
			}
			if err := of.Close(); err != nil {
				return err
			}
		}
	}
}

func (m *Manager) ensureStandaloneWebBundle(ctx context.Context, cfg config.Config, channel string, force bool) (string, error) {
	if !force {
		if _, err := os.Stat(filepath.Join(cfg.WebDir, "index.html")); err == nil {
			return cfg.AppDir, nil
		}
	}
	rel, err := fetchLatestRelease(ctx, m.HTTP, channel)
	if err != nil {
		return cfg.AppDir, err
	}
	return m.installWebBundle(ctx, cfg, rel)
}

func (m *Manager) installWebBundle(ctx context.Context, cfg config.Config, rel githubRelease) (string, error) {
	var webAsset *githubAsset
	for i := range rel.Assets {
		if strings.HasPrefix(rel.Assets[i].Name, "neorecall-web-") && strings.HasSuffix(rel.Assets[i].Name, ".tar.gz") {
			webAsset = &rel.Assets[i]
			break
		}
	}
	if webAsset == nil {
		return cfg.AppDir, errors.New("release does not contain neorecall-web bundle")
	}
	bundleFile := filepath.Join(cfg.Paths.RuntimeDir, webAsset.Name)
	if err := downloadVerifiedAsset(ctx, m.HTTP, *webAsset, bundleFile, 0o600); err != nil {
		return cfg.AppDir, err
	}
	defer os.Remove(bundleFile)

	appRoot := filepath.Join(cfg.Paths.RuntimeDir, "app")
	staging := appRoot + ".staging"
	_ = os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return cfg.AppDir, err
	}
	if err := ExtractTarGZSafe(bundleFile, staging); err != nil {
		_ = os.RemoveAll(staging)
		return cfg.AppDir, err
	}
	if _, err := os.Stat(filepath.Join(staging, "flutter_app", "build", "web", "index.html")); err != nil {
		_ = os.RemoveAll(staging)
		return cfg.AppDir, fmt.Errorf("downloaded web bundle is incomplete: %w", err)
	}
	backup, err := os.MkdirTemp(cfg.Paths.RuntimeDir, ".web-previous-")
	if err != nil {
		return cfg.AppDir, err
	}
	if err := os.Remove(backup); err != nil {
		return cfg.AppDir, err
	}
	hadPrevious := false
	if err := os.Rename(appRoot, backup); err == nil {
		hadPrevious = true
	} else if !os.IsNotExist(err) {
		return cfg.AppDir, err
	}
	restore := func() error {
		if err := os.RemoveAll(appRoot); err != nil {
			return err
		}
		if hadPrevious {
			return os.Rename(backup, appRoot)
		}
		return nil
	}
	if err := os.Rename(staging, appRoot); err != nil {
		if restoreErr := restore(); restoreErr != nil {
			return cfg.AppDir, errors.Join(err, restoreErr)
		}
		return cfg.AppDir, err
	}
	if err := envfile.Upsert(cfg.Paths.EnvFile, "NEORECALL_APP_DIR", appRoot); err != nil {
		if restoreErr := restore(); restoreErr != nil {
			return cfg.AppDir, errors.Join(err, restoreErr)
		}
		return cfg.AppDir, err
	}
	if hadPrevious {
		_ = os.RemoveAll(backup)
	}
	return appRoot, nil
}
