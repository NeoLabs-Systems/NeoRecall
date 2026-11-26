package manager

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"github.com/NeoLabs-Systems/neolabs-go/cli/envfile"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/cli/service"
	"github.com/NeoLabs-Systems/neolabs-go/cli/update"
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

// runtimeSource is where NeoRecall's signed runtimes are published, with the
// key that verifies them.
func (m *Manager) runtimeSource() (update.Source, error) {
	publicKey := strings.TrimSpace(m.RuntimePublicKey)
	if publicKey == "" {
		var err error
		publicKey, err = signing.PublicKey()
		if err != nil {
			return update.Source{}, err
		}
	}
	client := &release.Client{HTTP: m.HTTP, UserAgent: "NeoRecall CLI " + m.Version}
	if m.ReleaseClientFactory != nil {
		client = m.ReleaseClientFactory()
	}
	return runtimeSourceFor(publicKey, client), nil
}

func runtimeSourceFor(publicKey string, client *release.Client) update.Source {
	return update.Source{
		Client: client, ManifestPrefix: runtimebundle.ManifestPrefix, PublicKey: publicKey, SchemaVersion: 1,
		Targets: release.Targets{"linux": {"x64", "arm64"}, "macos": {"x64", "arm64"}, "windows": {"x64"}},
	}
}

// selectRuntime verifies a release's signed manifest and picks this computer's
// runtime.
func selectRuntime(ctx context.Context, source update.Source, rel githubRelease, version string) (update.Candidate, error) {
	signed := release.Release{Tag: rel.TagName, ManifestName: runtimebundle.ManifestPrefix + version + ".json", Assets: map[string]string{}}
	for _, asset := range rel.Assets {
		signed.Assets[asset.Name] = asset.BrowserDownloadURL
	}
	return source.Select(ctx, signed)
}

// stageSignedRuntime verifies the signed manifest and archive before touching
// the active version. It deliberately refuses an incomplete signed release.
func (m *Manager) stageSignedRuntime(ctx context.Context, cfg config.Config, rel githubRelease, version string) error {
	source, err := m.runtimeSource()
	if err != nil {
		return err
	}
	return stageRuntime(ctx, cfg, source, rel, version)
}

func stageRuntimeFromManifest(ctx context.Context, cfg config.Config, rel githubRelease, version, publicKey string, client *release.Client) error {
	return stageRuntime(ctx, cfg, runtimeSourceFor(publicKey, client), rel, version)
}

func stageRuntime(ctx context.Context, cfg config.Config, source update.Source, rel githubRelease, version string) error {
	candidate, err := selectRuntime(ctx, source, rel, version)
	if err != nil {
		return err
	}
	archive, err := source.Download(ctx, runtimeStore(cfg), candidate)
	if err != nil {
		return err
	}
	return update.Unpack(runtimeStore(cfg), version, archive, false)
}

func (m *Manager) updateSignedRuntime(ctx context.Context, cfg config.Config, rel githubRelease, before, version string) (bool, error) {
	store := runtimeStore(cfg)
	previous := ""
	if current, err := store.Current(); err == nil {
		if current.Version == version {
			return false, errors.New("the selected runtime is already active")
		}
		previous = current.Version
	}
	source, err := m.runtimeSource()
	if err != nil {
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
	dir, err := store.RuntimeDir(version)
	if err != nil {
		return false, err
	}
	appDir := filepath.Join(dir, "app")
	binary := filepath.Join(appDir, "bin", runtimeBinaryName())
	startupTimeout := m.RuntimeStartupTimeout
	if startupTimeout <= 0 {
		startupTimeout = 60 * time.Second
	}
	recoveryTimeout := m.RuntimeRollbackTimeout
	if recoveryTimeout <= 0 {
		recoveryTimeout = 30 * time.Second
	}
	start := func(install bool) error {
		if !wasInstalled && !wasRunning {
			return nil
		}
		if !wasInstalled {
			return sm.StartFallback()
		}
		if install {
			return sm.Install()
		}
		return sm.Launch()
	}
	stop := func() {
		if wasInstalled || wasRunning {
			m.stopManagedService(cfg, sm)
		}
	}

	var backup func(context.Context) error
	if _, err := os.Stat(cfg.Paths.Database); err == nil {
		backup = func(ctx context.Context) error { return m.cmdBackup(ctx, nil) }
	} else if !os.IsNotExist(err) {
		return false, err
	}
	var candidate update.Candidate
	var archive string
	err = update.Apply(ctx, m.UI, update.Plan{
		App: "NeoRecall", From: before, To: version, Backup: backup, RollbackTimeout: recoveryTimeout + 5*time.Second,
		Download: func(ctx context.Context) (err error) {
			if candidate, err = selectRuntime(ctx, source, rel, version); err != nil {
				return err
			}
			archive, err = source.Download(ctx, store, candidate)
			return err
		},
		Install: func(context.Context) error { return update.Unpack(store, version, archive, false) },
		Restart: func(context.Context) error {
			stop()
			if err := store.Activate(version); err != nil {
				return err
			}
			sm.Spec.Program, sm.Spec.WorkDir = binary, appDir
			for i := range sm.Spec.Env {
				if sm.Spec.Env[i].Key == "NEORECALL_APP_DIR" {
					sm.Spec.Env[i].Value = appDir
				}
			}
			return start(true)
		},
		Verify: func(ctx context.Context) error {
			if !wasInstalled && !wasRunning {
				return nil
			}
			return m.waitForServerVersion(ctx, cfg.Port, version, startupTimeout)
		},
		Rollback: func(ctx context.Context) error {
			stop()
			if err := restoreRuntimeSnapshot(markerPath, oldMarker, snapshot); err != nil {
				return err
			}
			sm.Spec = oldSpec
			if !wasInstalled && !wasRunning {
				return nil
			}
			// Without a saved service file the old definition is written again.
			if err := start(snapshot.path == ""); err != nil {
				return err
			}
			return m.waitForServerVersion(ctx, cfg.Port, before, recoveryTimeout)
		},
	})
	if err != nil {
		return update.RolledBack(err), err
	}
	if err := refreshRuntimeLauncher(binary, store.Root); err != nil {
		m.UI.Warn("NeoRecall updated, but the command-line launcher could not be refreshed: " + err.Error())
	}
	if err := store.Prune(version, previous); err != nil {
		m.UI.Warn("Old runtime cleanup failed: " + err.Error())
	}
	update.Ready(m.UI, "NeoRecall", version, fmt.Sprintf("http://localhost:%d", cfg.Port),
		"Your recordings, memories and accounts were kept.")
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
	invoked := release.InvocationPath(os.Args[0])
	if strings.HasPrefix(invoked, filepath.Clean(storeRoot)+string(os.PathSeparator)) {
		return nil
	}
	return update.RefreshLauncher(invoked, os.Getenv("NEORECALL_BIN_DIR"), runtimeBinaryName(), binary)
}
