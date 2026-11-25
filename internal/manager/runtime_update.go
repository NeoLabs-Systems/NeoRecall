package manager

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"github.com/NeoLabs-Systems/neolabs-go/cli/envfile"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/cli/service"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/runtimebundle"
	"github.com/NeoLabs-Systems/neorecall/internal/signing"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
)

func runtimeBinaryName() string {
	if runtime.GOOS == "windows" {
		return "neorecall.exe"
	}
	return "neorecall"
}

func (m *Manager) releaseAPIBase() string {
	if strings.TrimSpace(m.ReleaseAPIBase) != "" {
		return m.ReleaseAPIBase
	}
	return "https://api.github.com"
}

func runtimeStore(cfg config.Config) release.RuntimeStore {
	return release.RuntimeStore{Root: filepath.Join(cfg.Paths.Home, "app"), SchemaVersion: 1,
		RequiredFiles: []string{filepath.Join("app", "bin", runtimeBinaryName()), filepath.Join("app", "flutter_app", "build", "web", "index.html")}}
}

func hasSignedRuntime(rel githubRelease, version string) bool {
	prefix := runtimebundle.ManifestPrefix + version + ".json"
	for _, asset := range rel.Assets {
		if asset.Name == prefix || asset.Name == prefix+".sig" {
			return true
		}
	}
	return false
}

// bootstrapSignedRuntime installs a verified bundle on a fresh standalone
// installation. Existing installations migrate through the update path.
func (m *Manager) bootstrapSignedRuntime(ctx context.Context, args []string) (string, error) {
	if cli.HasFlag(args, "--skip-web") {
		return "", nil
	}
	cfg, err := m.loadConfig()
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(cfg.Paths.Database); err == nil {
		return "", nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(cfg.AppDir, ".git")); err == nil {
		return "", nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(runtimeStore(cfg).Root, "current.json")); err == nil {
		return "", nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	channel := (&updates.Service{Cfg: func() config.Config { return cfg }}).Channel()
	if requested, ok := cli.FlagValue(args, "--channel"); ok {
		if parsed := release.ParseChannel(requested); parsed != "" {
			channel = parsed
		}
	}
	rel, err := fetchLatestRelease(ctx, m.HTTP, channel)
	if err != nil {
		return "", err
	}
	version := strings.TrimPrefix(rel.TagName, "v")
	if !hasSignedRuntime(rel, version) {
		return "", nil
	}
	if err := m.UI.Step("Downloading the verified NeoRecall runtime", "Downloaded the verified NeoRecall runtime", func() error {
		return m.stageSignedRuntime(ctx, cfg, rel, version)
	}); err != nil {
		return "", err
	}
	if err := runtimeStore(cfg).Activate(version); err != nil {
		return "", err
	}
	return version, nil
}

// stageSignedRuntime verifies the signed manifest and archive before touching
// the active version. It deliberately refuses an incomplete signed release.
func (m *Manager) stageSignedRuntime(ctx context.Context, cfg config.Config, rel githubRelease, version string) error {
	publicKey := strings.TrimSpace(m.RuntimePublicKey)
	if publicKey == "" {
		var err error
		publicKey, err = signing.PublicKey()
		if err != nil {
			return err
		}
	}
	client := &release.Client{HTTP: m.HTTP, UserAgent: "NeoRecall CLI " + m.Version}
	if m.ReleaseClientFactory != nil {
		client = m.ReleaseClientFactory()
	}
	return stageRuntimeFromManifest(ctx, cfg, rel, version, publicKey, client)
}

func stageRuntimeFromManifest(ctx context.Context, cfg config.Config, rel githubRelease, version, publicKey string, client *release.Client) error {
	name := runtimebundle.ManifestPrefix + version + ".json"
	signed := release.Release{Tag: rel.TagName, ManifestName: name, Assets: map[string]string{}}
	for _, asset := range rel.Assets {
		signed.Assets[asset.Name] = asset.BrowserDownloadURL
	}
	if signed.Assets[name] == "" || signed.Assets[name+".sig"] == "" {
		return errors.New("signed runtime manifest or signature is missing")
	}
	raw, err := client.FetchVerifiedManifest(ctx, signed, publicKey)
	if err != nil {
		return err
	}
	var manifest release.RuntimeManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return fmt.Errorf("invalid runtime manifest: %w", err)
	}
	if manifest.SchemaVersion != 1 || manifest.Version != version {
		return errors.New("runtime manifest does not match the selected release")
	}
	platform := runtime.GOOS
	if platform == "darwin" {
		platform = "macos"
	}
	arch := runtime.GOARCH
	if arch == "amd64" {
		arch = "x64"
	}
	supported := release.Targets{"linux": {"x64", "arm64"}, "macos": {"x64", "arm64"}, "windows": {"x64"}}
	var chosen *release.Artifact
	for _, artifact := range manifest.Artifacts {
		if artifact.Platform != platform || artifact.Architecture != arch {
			continue
		}
		if chosen != nil {
			return errors.New("runtime manifest has duplicate platform artifacts")
		}
		normalized, err := release.NormalizeArtifact(artifact, supported)
		if err != nil {
			return err
		}
		chosen = &normalized
	}
	if chosen == nil || signed.Assets[chosen.AssetName] == "" {
		return errors.New("signed runtime for this computer is missing")
	}
	if err := os.MkdirAll(cfg.Paths.RuntimeDir, 0o700); err != nil {
		return err
	}
	temp, err := os.MkdirTemp(cfg.Paths.RuntimeDir, ".runtime-download-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	archive := filepath.Join(temp, "runtime.zip")
	if err := client.Download(ctx, signed.Assets[chosen.AssetName], archive, chosen.SizeBytes, chosen.SHA256); err != nil {
		return err
	}
	return runtimeStore(cfg).InstallArchive(version, archive)
}

func (m *Manager) updateSignedRuntime(ctx context.Context, cfg config.Config, rel githubRelease, before, version string) (bool, error) {
	store := runtimeStore(cfg)
	if current, err := store.Current(); err == nil && current.Version == version {
		return false, errors.New("the selected runtime is already active")
	}
	m.UI.Title("Updating NeoRecall", fmt.Sprintf("%s → %s", before, version))
	if _, err := os.Stat(cfg.Paths.Database); err == nil {
		if err := m.UI.Step("Saving a backup of your data", "Saved a backup of your data", func() error { return m.cmdBackup(ctx, nil) }); err != nil {
			return false, err
		}
	} else if !os.IsNotExist(err) {
		return false, err
	}
	if err := m.UI.Step("Downloading the new version", "Downloaded the new version", func() error { return m.stageSignedRuntime(ctx, cfg, rel, version) }); err != nil {
		return false, err
	}
	sm, err := m.serviceManager(cfg)
	if err != nil {
		return false, err
	}
	wasInstalled := sm.Installed()
	wasRunning := cli.PortOpen(cfg.Port) || m.RestartAfterLegacyMigration
	snapshot, oldSpec := m.snapshotService(cfg), sm.Spec
	oldSpec.Env = append([]service.EnvVar(nil), sm.Spec.Env...)
	markerPath := filepath.Join(store.Root, "current.json")
	oldMarker, markerErr := os.ReadFile(markerPath)
	if markerErr != nil && !os.IsNotExist(markerErr) {
		return false, markerErr
	}
	previous := ""
	if current, err := store.Current(); err == nil {
		previous = current.Version
	}
	dir, err := store.RuntimeDir(version)
	if err != nil {
		return false, err
	}
	appDir := filepath.Join(dir, "app")
	binary := filepath.Join(appDir, "bin", runtimeBinaryName())
	rollback := func(cause error) (bool, error) {
		if wasInstalled || wasRunning {
			m.stopManagedService(cfg, sm)
		}
		restoreErr := restoreRuntimeSnapshot(markerPath, oldMarker, snapshot)
		sm.Spec = oldSpec
		if wasInstalled || wasRunning {
			var err error
			if wasInstalled {
				if snapshot.path == "" {
					err = sm.Install()
				} else {
					err = sm.Launch()
				}
			} else {
				err = sm.StartFallback()
			}
			if err != nil {
				restoreErr = errors.Join(restoreErr, err)
			} else {
				recoveryTimeout := m.RuntimeRollbackTimeout
				if recoveryTimeout <= 0 {
					recoveryTimeout = 30 * time.Second
				}
				recoveryCtx, cancel := context.WithTimeout(context.Background(), recoveryTimeout+5*time.Second)
				err = m.waitForServerVersion(recoveryCtx, cfg.Port, before, recoveryTimeout)
				cancel()
				if err != nil {
					restoreErr = errors.Join(restoreErr, err)
				}
			}
		}
		if restoreErr != nil {
			return false, errors.Join(cause, fmt.Errorf("rollback failed: %w", restoreErr))
		}
		return true, fmt.Errorf("%w; restored NeoRecall %s", cause, before)
	}
	if wasInstalled || wasRunning {
		m.stopManagedService(cfg, sm)
	}
	if err := store.Activate(version); err != nil {
		return rollback(err)
	}
	sm.Spec.Program, sm.Spec.WorkDir = binary, appDir
	for i := range sm.Spec.Env {
		if sm.Spec.Env[i].Key == "NEORECALL_APP_DIR" {
			sm.Spec.Env[i].Value = appDir
		}
	}
	if wasInstalled || wasRunning {
		var err error
		if wasInstalled {
			err = sm.Install()
		} else {
			err = sm.StartFallback()
		}
		if err != nil {
			return rollback(err)
		}
		startupTimeout := m.RuntimeStartupTimeout
		if startupTimeout <= 0 {
			startupTimeout = 60 * time.Second
		}
		if err := m.waitForServerVersion(ctx, cfg.Port, version, startupTimeout); err != nil {
			return rollback(err)
		}
	}
	if err := refreshRuntimeLauncher(binary, store.Root); err != nil {
		m.UI.Warn("NeoRecall updated, but the command-line launcher could not be refreshed: " + err.Error())
	}
	if err := store.Prune(version, previous); err != nil {
		m.UI.Warn("Old runtime cleanup failed: " + err.Error())
	}
	m.UI.OK(fmt.Sprintf("NeoRecall %s is ready", version))
	return false, nil
}

func (m *Manager) stopManagedService(cfg config.Config, sm *service.Manager) {
	if m.StopManagedService != nil {
		m.StopManagedService(cfg, sm)
		return
	}
	m.stopRunningProcesses(cfg, sm)
}

func restoreRuntimeSnapshot(markerPath string, marker []byte, snapshot serviceSnapshot) error {
	var result error
	if marker != nil {
		result = envfile.WriteAtomic(markerPath, marker, 0o600)
	} else if err := os.Remove(markerPath); err != nil && !os.IsNotExist(err) {
		result = err
	}
	if snapshot.path != "" && len(snapshot.content) != 0 {
		result = errors.Join(result, envfile.WriteAtomic(snapshot.path, snapshot.content, 0o644))
	}
	return result
}

func refreshRuntimeLauncher(binary, storeRoot string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	binDir := strings.TrimSpace(os.Getenv("NEORECALL_BIN_DIR"))
	if binDir == "" {
		binDir = filepath.Join(home, ".local", "bin")
	}
	launcher, err := filepath.Abs(filepath.Join(binDir, runtimeBinaryName()))
	if err != nil {
		return err
	}
	if filepath.Clean(exe) != launcher {
		return nil
	}
	if strings.HasPrefix(exe, filepath.Clean(storeRoot)+string(os.PathSeparator)) {
		return nil
	}
	source, err := os.Open(binary)
	if err != nil {
		return err
	}
	defer source.Close()
	temp, err := os.CreateTemp(binDir, ".neorecall-update-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	_, err = io.Copy(temp, source)
	if err == nil {
		err = temp.Chmod(0o755)
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temp.Name(), launcher)
}
