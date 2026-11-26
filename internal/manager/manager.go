// Package manager implements NeoRecall's CLI management commands (setup, service control,
// models, diagnostics, backups, accounts, env, updates, and verify-no-audio).
package manager

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/cli"
	"github.com/NeoLabs-Systems/neolabs-go/cli/envfile"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/cli/service"
	"github.com/NeoLabs-Systems/neolabs-go/cli/update"
	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/runtimecfg"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/models"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
)

const defaultPort = 4500

type Booter func(ctx context.Context, use func(context.Context, *dbx.DB, config.Config) error) error

type Manager struct {
	Getenv                      func(string) string
	UserHome                    string
	Cwd                         string
	AppDir                      string
	Version                     string
	In                          io.Reader
	Out                         io.Writer
	Err                         io.Writer
	UI                          *cli.UI
	HTTP                        *http.Client
	ReleaseAPIBase              string
	RuntimePublicKey            string
	RestartAfterLegacyMigration bool
	RuntimeStartupTimeout       time.Duration
	RuntimeRollbackTimeout      time.Duration
	StopManagedService          func(config.Config, *service.Manager)
	ServiceFactory              func(config.Config) (*service.Manager, error)
	ReleaseClientFactory        func() *release.Client
	Boot                        Booter
}

func New(args []string) (*Manager, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("find home directory: %w", err)
	}
	cwd, _ := os.Getwd()
	silent := cli.HasFlag(args, "--json") || cli.HasFlag(args, "--quiet")
	m := &Manager{
		Getenv:   os.Getenv,
		UserHome: home,
		Cwd:      cwd,
		Version:  config.Version,
		In:       os.Stdin,
		Out:      os.Stdout,
		Err:      os.Stderr,
		UI:       cli.NewUI(silent),
		HTTP:     ssrf.NewClient(ssrf.Options{Timeout: 60 * time.Second}),
	}
	cfg, cerr := m.loadConfig()
	if cerr == nil {
		m.AppDir = cfg.AppDir
		if current, err := runtimeStore(cfg).Current(); err == nil {
			m.Version = current.Version
		}
	} else {
		m.AppDir = cwd
	}
	return m, nil
}

func (m *Manager) loadConfig() (config.Config, error) {
	p := config.ResolvePaths(m.Getenv, m.UserHome)
	_ = runtimecfg.LoadEnvFile(p.EnvFile, os.LookupEnv, os.Setenv)
	cfg, err := config.Load(m.Getenv, m.UserHome, m.Cwd)
	if err != nil {
		return cfg, err
	}
	if marker, err := runtimeStore(cfg).Current(); err == nil {
		dir, err := runtimeStore(cfg).RuntimeDir(marker.Version)
		if err != nil {
			return cfg, err
		}
		cfg.AppDir = filepath.Join(dir, "app")
		if m.Getenv("NEORECALL_WEB_DIR") == "" {
			cfg.WebDir = filepath.Join(cfg.AppDir, "flutter_app", "build", "web")
		}
		if m.Getenv("NEORECALL_LANDING_DIR") == "" {
			cfg.Landing = filepath.Join(cfg.AppDir, "landing")
		}
	}
	return cfg, nil
}

func (m *Manager) withDB(ctx context.Context, fn func(context.Context, *dbx.DB, config.Config) error) error {
	if m.Boot != nil {
		return m.Boot(ctx, fn)
	}
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := cfg.Paths.Ensure(); err != nil {
		return err
	}
	if _, err := schema.EnsurePlaintextLegacyDB(ctx, cfg.Paths.Database, cfg.Paths.SecretKey, cfg.AppDir, cfg.Paths.Home); err != nil {
		return err
	}
	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		return err
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		return err
	}
	return fn(ctx, db, cfg)
}

func (m *Manager) serviceManager(cfg config.Config) (*service.Manager, error) {
	if m.ServiceFactory != nil {
		return m.ServiceFactory(cfg)
	}
	exe, err := os.Executable()
	if err != nil {
		exe = "neorecall"
	}
	if marker, err := runtimeStore(cfg).Current(); err == nil {
		dir, err := runtimeStore(cfg).RuntimeDir(marker.Version)
		if err != nil {
			return nil, err
		}
		exe = filepath.Join(dir, "app", "bin", runtimeBinaryName())
	}
	workDir := cfg.AppDir
	if workDir == "" {
		workDir = cfg.Paths.Home
	}
	pathParts := []string{}
	seenDir := map[string]bool{}
	addDir := func(d string) {
		if d != "" && !seenDir[d] {
			seenDir[d] = true
			pathParts = append(pathParts, d)
		}
	}
	if exeDir := filepath.Dir(exe); exeDir != "" && exeDir != "." {
		addDir(exeDir)
	}
	for _, d := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"} {
		addDir(d)
	}
	for _, d := range filepath.SplitList(m.Getenv("PATH")) {
		addDir(d)
	}

	env := []service.EnvVar{
		{Key: "NEORECALL_HOME", Value: cfg.Paths.Home},
		{Key: "PATH", Value: strings.Join(pathParts, string(os.PathListSeparator))},
	}
	if workDir != "" {
		env = append(env, service.EnvVar{Key: "NEORECALL_APP_DIR", Value: workDir})
	}
	spec := service.Spec{
		Label:       config.DefaultServiceLabel,
		Name:        "neorecall",
		TaskName:    "NeoRecall",
		Description: "NeoRecall personal memory backend",
		Program:     exe,
		Args:        []string{"serve"},
		WorkDir:     workDir,
		Env:         env,
		EnvFile:     cfg.Paths.EnvFile,
		LogDir:      cfg.Paths.Logs,
		LogName:     "neorecall",
		PIDFile:     cfg.Paths.PIDFile,
	}
	platform := runtime.GOOS
	if platform == "darwin" {
		platform = "macos"
	}
	return service.New(spec, platform)
}

func (m *Manager) commands() []cli.Command {
	return []cli.Command{
		{Name: "install", Usage: "install [--quick|--full|--no-models]", Summary: "Set NeoRecall up and start it with this computer", Run: m.cmdInstall},
		{Name: "setup", Usage: "setup [--quick|--full|--no-models]", Summary: "Configure NeoRecall, download models, and start it", Run: m.cmdSetup},
		{Name: "start", Usage: "start [--foreground]", Summary: "Start NeoRecall", Run: m.cmdStart},
		{Name: "stop", Usage: "stop", Summary: "Stop NeoRecall", Run: m.cmdStop},
		{Name: "restart", Usage: "restart", Summary: "Restart NeoRecall", Run: m.cmdRestart},
		{Name: "status", Usage: "status [--details]", Summary: "Show whether everything works", Run: m.cmdStatus},
		{Name: "doctor", Usage: "doctor", Summary: "Find problems and offer to fix them", Run: m.cmdDoctor},
		{Name: "repair", Aliases: []string{"fix"}, Usage: "repair", Summary: "Verify models, database, and restart", Run: m.cmdRepair},
		{Name: "logs", Usage: "logs", Summary: "Show recent NeoRecall logs", Run: m.cmdLogs},
		{Name: "models", Usage: "models [download|verify|prune]", Summary: "Download, verify, or prune pinned ML models", Run: m.cmdModels},
		{Name: "verify-no-audio", Usage: "verify-no-audio", Summary: "Verify zero unreferenced or retained source audio remains", Run: m.cmdVerifyNoAudio},
		{Name: "channel", Usage: "channel [stable|beta]", Summary: "Show or switch the update channel", Run: m.cmdChannel},
		{Name: "update", Usage: "update [stable|beta] [--notes|--check] [--json]", Summary: "Check or apply updates", Run: m.cmdUpdate},
		{Name: "env", Usage: "env [list|get|set|unset]", Summary: "Read and change settings in the .env file", Run: m.cmdEnv},
		{Name: "admin", Usage: "admin [list|grant|revoke] <user> [--json]", Summary: "Manage admin accounts", Run: m.cmdAdmin},
		{Name: "account", Usage: "account create --username U --password P [--admin]", Summary: "Create a user account from CLI", Run: m.cmdAccount},
		{Name: "reset-password", Usage: "reset-password <user> [--password-file PATH]", Summary: "Set a new password and sign the account out", Run: m.cmdResetPassword},
		{Name: "backup", Usage: "backup [list]", Summary: "Save an encrypted backup or list backups", Run: m.cmdBackup},
		{Name: "restore", Usage: "restore <key> [--output PATH]", Summary: "Restore an encrypted backup safely beside the DB", Run: m.cmdRestore},
		{Name: "rebuild-web", Usage: "rebuild-web", Summary: "Rebuild flutter_app/build/web (developers)", Run: m.cmdRebuildWeb},
		{Name: "uninstall", Usage: "uninstall", Summary: "Remove startup registration (data stays)", Run: m.cmdUninstall},
		{Name: "serve", Usage: "serve", Summary: "Run the server in the foreground"},
		{Name: "healthcheck", Usage: "healthcheck", Summary: "Exit 0 when /health responds (containers)"},
		{Name: "version", Aliases: []string{"--version", "-V", "-v"}, Usage: "version", Summary: "Print the installed version", Run: func(context.Context, []string) error {
			ver := m.Version
			if ver == "" {
				ver = config.Version
			}
			fmt.Fprintln(m.Out, ver)
			return nil
		}},
		{Name: "help", Aliases: []string{"--help", "-h"}, Usage: "help", Summary: "Show this help", Run: func(context.Context, []string) error {
			m.printHelp()
			return nil
		}},
	}
}

func (m *Manager) printHelp() {
	ver := m.Version
	if ver == "" {
		ver = config.Version
	}
	fmt.Fprintf(m.Out, "\n  NeoRecall %s\n\n  Usage: neorecall <command>\n\n%s\n", ver, cli.Help(m.commands()))
}

func Run(ctx context.Context, args []string, boot Booter) error {
	m, err := New(args)
	if err != nil {
		return err
	}
	m.Boot = boot
	if len(args) == 0 {
		return m.cmdHome(ctx)
	}
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := cfg.Paths.Ensure(); err != nil {
		return err
	}
	cmd := cli.Find(m.commands(), args[0])
	if cmd == nil || cmd.Run == nil {
		return fmt.Errorf("%q isn't a neorecall command. Run `neorecall help` to see what you can do", args[0])
	}
	return cmd.Run(ctx, args[1:])
}

func (m *Manager) cmdHome(ctx context.Context) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if _, err := os.Stat(cfg.Paths.EnvFile); os.IsNotExist(err) && m.UI.Interactive() {
		return m.cmdInstall(ctx, nil)
	}
	_, running := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/health", cfg.Port))
	m.UI.Blank()
	if running {
		m.UI.Item("ok", m.UI.Bold("NeoRecall is running"), fmt.Sprintf("http://localhost:%d", cfg.Port))
	} else {
		m.UI.Item("warn", m.UI.Bold("NeoRecall isn't running"), "run neorecall start")
	}
	m.UI.Blank()
	return m.UI.HomeMenu("neorecall", cli.HomeActions{
		AppName: "NeoRecall", Running: running, ShowUpdate: true,
		SettingsHint: "models, address, integrations",
		Open: func() error {
			opener := map[string]string{"darwin": "open", "windows": "explorer"}[runtime.GOOS]
			if opener == "" {
				opener = "xdg-open"
			}
			return exec.Command(opener, fmt.Sprintf("http://localhost:%d", cfg.Port)).Start()
		},
		Start:    func() error { return m.cmdStart(ctx, nil) },
		Status:   func() error { return m.cmdStatus(ctx, nil) },
		Restart:  func() error { return m.cmdRestart(ctx, nil) },
		Update:   func() error { return m.cmdUpdate(ctx, nil) },
		Settings: func() error { return m.cmdSetup(ctx, nil) },
		Doctor:   func() error { return m.cmdDoctor(ctx, nil) },
		Help:     func() error { m.printHelp(); return nil },
	})
}

func Healthcheck(ctx context.Context, getenv func(string) string) error {
	home, _ := os.UserHomeDir()
	cwd, _ := os.Getwd()
	if getenv == nil {
		getenv = os.Getenv
	}
	p := config.ResolvePaths(getenv, home)
	_ = runtimecfg.LoadEnvFile(p.EnvFile, os.LookupEnv, os.Setenv)
	cfg, err := config.Load(getenv, home, cwd)
	if err != nil {
		return err
	}
	port := cfg.Port
	if port <= 0 {
		port = defaultPort
	}
	c := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/health", port), nil)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthcheck returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func (m *Manager) ensureDefaultEnvFile(cfg config.Config) error {
	if _, err := os.Stat(cfg.Paths.EnvFile); err == nil {
		return nil
	}
	if err := runtimecfg.EnsurePrivateDir(filepath.Dir(cfg.Paths.EnvFile)); err != nil {
		return err
	}
	port := cfg.Port
	if port <= 0 {
		if avail, perr := cli.FindAvailablePort(defaultPort, defaultPort+20); perr == nil {
			port = avail
		} else {
			port = defaultPort
		}
	}
	secret := randomHex(32)
	content := strings.Join([]string{
		fmt.Sprintf("NEORECALL_PORT=%d", port),
		"NEORECALL_HOST=127.0.0.1",
		"NEORECALL_SECRET=" + secret,
		"NEORECALL_RELEASE_CHANNEL=stable",
		"",
	}, "\n")
	return envfile.WriteAtomic(cfg.Paths.EnvFile, []byte(content), 0o600)
}

func randomHex(bytesLen int) string {
	b := make([]byte, bytesLen)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (m *Manager) cmdSetup(ctx context.Context, args []string) error {
	if ch, ok := cli.FlagValue(args, "--channel"); ok {
		if parsed := release.ParseChannel(ch); parsed != "" {
			cfg0, cerr := m.loadConfig()
			if cerr == nil {
				_ = m.ensureDefaultEnvFile(cfg0)
				_ = envfile.Upsert(cfg0.Paths.EnvFile, "NEORECALL_RELEASE_CHANNEL", parsed)
			}
		}
	}
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := m.ensureDefaultEnvFile(cfg); err != nil {
		return err
	}
	cfg, err = m.loadConfig()
	if err != nil {
		return err
	}

	m.UI.Title("Setting up NeoRecall", cfg.Paths.Home)
	legacy := InspectLegacyJS(cfg, m.UserHome, m.Getenv)
	var backupKey string
	if legacy.NeedsMigration {
		m.UI.Info("Detected existing NeoRecall installation; preserving database, keys, and settings.")
		sm, _ := m.serviceManager(cfg)
		m.stopRunningProcesses(cfg, sm)
		bk, merr := m.migrateLegacyJSState(ctx, cfg, legacy)
		if merr != nil {
			return merr
		}
		backupKey = bk
		cfg, err = m.loadConfig()
		if err != nil {
			return err
		}
	}

	channel := (&updates.Service{Cfg: func() config.Config { return cfg }}).Channel()
	_, webStatErr := os.Stat(filepath.Join(cfg.WebDir, "index.html"))
	forceWeb := cli.HasFlag(args, "--refresh-web") ||
		(legacy.NeedsMigration && (cfg.AppDir == "" || strings.HasPrefix(cfg.AppDir, cfg.Paths.RuntimeDir)))
	if webStatErr != nil && !cli.HasFlag(args, "--skip-web") {
		forceWeb = true
	}
	if forceWeb && !cli.HasFlag(args, "--skip-web") {
		if err := m.UI.Step("Downloading bundled web UI", "Web UI ready", func() error {
			_, werr := m.ensureStandaloneWebBundle(ctx, cfg, channel, true)
			return werr
		}); err != nil {
			m.UI.Warn("Web UI bundle download skipped: " + err.Error())
		} else {
			cfg, _ = m.loadConfig()
		}
	}

	skipModels := cli.HasFlag(args, "--no-models")
	if !skipModels {
		if err := m.UI.Step("Downloading & verifying pinned ML models", "ML models verified", func() error {
			if _, err := models.DownloadAll(ctx, m.HTTP, cfg.AppDir, cfg.Paths.Models, nil); err != nil {
				return err
			}
			_, err := models.PruneRetired(cfg.AppDir, cfg.Paths.Models)
			return err
		}); err != nil {
			return err
		}
	}

	if err := m.UI.Step("Preparing database", "Database ready", func() error {
		return m.withDB(ctx, func(context.Context, *dbx.DB, config.Config) error { return nil })
	}); err != nil {
		return err
	}

	_ = WriteMigratedMarker(cfg, m.Version, backupKey, "setup complete")
	m.UI.OK("NeoRecall setup complete.")
	m.UI.Note(fmt.Sprintf("Start it with %s or %s.", m.UI.Command("neorecall serve"), m.UI.Command("neorecall start")))
	return nil
}

func (m *Manager) cmdInstall(ctx context.Context, args []string) (result error) {
	bootstrapped, err := m.bootstrapSignedRuntime(ctx, args)
	if err != nil {
		return err
	}
	defer func() {
		if result != nil && bootstrapped != "" {
			cfg, err := m.loadConfig()
			if err == nil {
				_ = os.Remove(filepath.Join(runtimeStore(cfg).Root, "current.json"))
			}
		}
	}()
	if err := m.cmdSetup(ctx, args); err != nil {
		return err
	}
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	sm, err := m.serviceManager(cfg)
	if err != nil {
		return err
	}
	snap := m.snapshotService(cfg)
	wasInstalled := sm.Installed()
	rollbackInstall := func() {
		if wasInstalled {
			restoreServiceSnapshot(snap, sm)
		} else {
			sm.Uninstall()
		}
	}
	m.stopRunningProcesses(cfg, sm)
	if err := sm.Install(); err != nil {
		rollbackInstall()
		return err
	}
	if bootstrapped != "" {
		err = m.waitForServerVersion(ctx, cfg.Port, bootstrapped, 30*time.Second)
	} else {
		err = m.waitForServer(ctx, cfg.Port, 30*time.Second)
	}
	if err != nil {
		rollbackInstall()
		return err
	}
	if bootstrapped != "" {
		dir, err := runtimeStore(cfg).RuntimeDir(bootstrapped)
		if err != nil {
			return err
		}
		if err := refreshRuntimeLauncher(filepath.Join(dir, "app", "bin", runtimeBinaryName()), runtimeStore(cfg).Root); err != nil {
			m.UI.Warn("NeoRecall installed, but the command-line launcher could not be refreshed: " + err.Error())
		}
	}
	m.UI.OK("NeoRecall installed and started.")
	return nil
}

func (m *Manager) cmdStart(ctx context.Context, _ []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := m.ensureDefaultEnvFile(cfg); err != nil {
		return err
	}
	sm, err := m.serviceManager(cfg)
	if err != nil {
		return err
	}
	legacy := InspectLegacyJS(cfg, m.UserHome, m.Getenv)
	if legacy.LegacyPlist || legacy.LegacySystemd {
		snap := m.snapshotService(cfg)
		m.stopRunningProcesses(cfg, sm)
		if err := sm.Install(); err != nil {
			restoreServiceSnapshot(snap, sm)
			return err
		}
	}
	if !sm.Installed() {
		if err := sm.StartFallback(); err != nil {
			return err
		}
	} else if err := sm.Launch(); err != nil {
		return err
	}
	return m.waitForServer(ctx, cfg.Port, 15*time.Second)
}

func (m *Manager) cmdStop(context.Context, []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	sm, err := m.serviceManager(cfg)
	if err != nil {
		return err
	}
	m.stopRunningProcesses(cfg, sm)
	m.UI.OK("NeoRecall stopped.")
	return nil
}

func (m *Manager) cmdRestart(ctx context.Context, args []string) error {
	_ = m.cmdStop(ctx, args)
	return m.cmdStart(ctx, args)
}

func (m *Manager) waitForServer(ctx context.Context, port int, timeout time.Duration) error {
	if port <= 0 {
		port = defaultPort
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if cli.PortOpen(port) {
			if _, ok := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/health", port)); ok {
				m.UI.OK(fmt.Sprintf("NeoRecall is running on http://127.0.0.1:%d", port))
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("NeoRecall did not answer on port %d within %s", port, timeout)
}

func fetchJSON(ctx context.Context, url string) (map[string]any, bool) {
	c := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, false
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 && resp.StatusCode != 503 {
		return nil, false
	}
	var out map[string]any
	if json.NewDecoder(resp.Body).Decode(&out) != nil {
		return nil, false
	}
	return out, true
}

func (m *Manager) cmdStatus(ctx context.Context, args []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	health, up := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/health", cfg.Port))
	ready, _ := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/ready", cfg.Port))
	fails, _ := models.VerifyAll(cfg.AppDir, cfg.Paths.Models)
	ff := transcription.ResolveFFmpegPath()

	if cli.HasFlag(args, "--json") {
		b, _ := json.MarshalIndent(map[string]any{
			"running":        up,
			"port":           cfg.Port,
			"health":         health,
			"ready":          ready,
			"modelsMissing":  len(fails),
			"ffmpegFound":    ff != "",
			"dataDir":        cfg.Paths.Home,
			"releaseChannel": (&updates.Service{Cfg: func() config.Config { return cfg }}).Channel(),
		}, "", "  ")
		fmt.Fprintln(m.Out, string(b))
		return nil
	}

	m.UI.Title("NeoRecall Status", cfg.Paths.Home)
	if up {
		m.UI.Item("ok", "Server", fmt.Sprintf("Running on port %d", cfg.Port))
	} else {
		m.UI.Item("warn", "Server", fmt.Sprintf("Not answering on port %d", cfg.Port))
	}
	if len(fails) == 0 {
		m.UI.Item("ok", "ML models", "Verified")
	} else {
		m.UI.Item("warn", "ML models", fmt.Sprintf("%d file(s) missing or invalid", len(fails)))
	}
	if ff != "" {
		m.UI.Item("ok", "ffmpeg", ff)
	} else {
		m.UI.Item("warn", "ffmpeg", "Not found in PATH")
	}
	if ready != nil {
		m.UI.Item("info", "Readiness", fmt.Sprintf("status=%v models=%v llm=%v vector=%v", ready["status"], ready["models"], ready["languageModel"], ready["vector"]))
	}
	if cli.HasFlag(args, "--details") {
		m.UI.Section("Paths")
		m.UI.Item("info", "Database", cfg.Paths.Database)
		m.UI.Item("info", "Env file", cfg.Paths.EnvFile)
		m.UI.Item("info", "Web UI", cfg.WebDir)
	}
	return nil
}

func (m *Manager) cmdDoctor(ctx context.Context, _ []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	m.UI.Title("Checking NeoRecall", cfg.Paths.Home)
	allOK := true
	check := func(ok bool, label, good, bad, fix string) {
		if ok {
			m.UI.Item("ok", label, good)
			return
		}
		allOK = false
		m.UI.Item("error", label, bad)
		if fix != "" {
			m.UI.Note("Fix: " + fix)
		}
	}

	_, envErr := os.Stat(cfg.Paths.EnvFile)
	check(envErr == nil, "Settings", "Saved", "Not set up yet", "neorecall setup")
	_, webErr := os.Stat(filepath.Join(cfg.WebDir, "index.html"))
	check(webErr == nil, "Browser UI", "Installed", "Missing", "neorecall rebuild-web")
	fails, _ := models.VerifyAll(cfg.AppDir, cfg.Paths.Models)
	check(len(fails) == 0, "Speech and search models", "Verified", fmt.Sprintf("%d file(s) missing", len(fails)), "neorecall models download")
	check(transcription.ResolveFFmpegPath() != "", "ffmpeg", "Installed", "Missing in PATH", "Install ffmpeg on your system")
	_, up := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/health", cfg.Port))
	check(up, "NeoRecall server", fmt.Sprintf("Running on port %d", cfg.Port), fmt.Sprintf("Not running on port %d", cfg.Port), "neorecall start")

	if allOK {
		m.UI.OK("No problems found.")
	}
	return nil
}

func (m *Manager) cmdRepair(ctx context.Context, args []string) error {
	if err := m.cmdSetup(ctx, args); err != nil {
		return err
	}
	cfg, _ := m.loadConfig()
	if sm, err := m.serviceManager(cfg); err == nil && sm.Installed() {
		return m.cmdRestart(ctx, args)
	}
	m.UI.OK("Repair complete.")
	return nil
}

func (m *Manager) cmdLogs(context.Context, []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	logFile := filepath.Join(cfg.Paths.Logs, "neorecall.log")
	raw, err := os.ReadFile(logFile)
	if err != nil {
		if os.IsNotExist(err) {
			m.UI.Info("NeoRecall has not written a log yet.")
			return nil
		}
		return err
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) > 200 {
		lines = lines[len(lines)-200:]
	}
	m.UI.Title("NeoRecall Logs", logFile)
	for _, line := range lines {
		fmt.Fprintln(m.Out, line)
	}
	return nil
}

func (m *Manager) cmdModels(ctx context.Context, args []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	sub := "download"
	if len(args) > 0 {
		sub = strings.ToLower(strings.TrimSpace(args[0]))
	}
	switch sub {
	case "download":
		res, err := models.DownloadAll(ctx, m.HTTP, cfg.AppDir, cfg.Paths.Models, nil)
		if err != nil {
			return err
		}
		fmt.Fprintf(m.Out, "Verified/downloaded %d model files in %s\n", len(res), cfg.Paths.Models)
		return nil
	case "verify":
		fails, err := models.VerifyAll(cfg.AppDir, cfg.Paths.Models)
		if err != nil {
			return err
		}
		if len(fails) > 0 {
			return fmt.Errorf("%d model file(s) failed verification (%s: %s)", len(fails), fails[0].Path, fails[0].Reason)
		}
		fmt.Fprintln(m.Out, "All pinned model files verified.")
		return nil
	case "prune":
		removed, err := models.PruneRetired(cfg.AppDir, cfg.Paths.Models)
		if err != nil {
			return err
		}
		fmt.Fprintf(m.Out, "Pruned %d retired model asset(s).\n", len(removed))
		return nil
	default:
		return errors.New("usage: neorecall models [download|verify|prune]")
	}
}

func (m *Manager) cmdVerifyNoAudio(ctx context.Context, _ []string) error {
	return m.withDB(ctx, func(ctx context.Context, db *dbx.DB, cfg config.Config) error {
		var badTerminal int
		if err := db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks
			WHERE state IN ('transcribed','silent') AND (temporary_path IS NOT NULL OR persisted_at IS NULL OR server_deleted_at IS NULL)`).Scan(&badTerminal); err != nil {
			return err
		}
		if badTerminal > 0 {
			return fmt.Errorf("%d terminal chunks violate the deletion receipt invariant", badTerminal)
		}

		rows, err := db.R.QueryContext(ctx, `SELECT temporary_path FROM audio_chunks WHERE temporary_path IS NOT NULL`)
		if err != nil {
			return err
		}
		refAudio := map[string]bool{}
		for rows.Next() {
			var p string
			if rows.Scan(&p) == nil {
				refAudio[p] = true
			}
		}
		rows.Close()
		if ents, rerr := os.ReadDir(cfg.Paths.AudioTmp); rerr == nil {
			for _, e := range ents {
				if !e.IsDir() {
					p := filepath.Join(cfg.Paths.AudioTmp, e.Name())
					if !refAudio[p] {
						return fmt.Errorf("unreferenced temporary audio remains: %s", p)
					}
				}
			}
		}

		if ents, rerr := os.ReadDir(cfg.Paths.AudioWork); rerr == nil {
			cutoff := time.Now().Add(-60 * time.Second)
			for _, e := range ents {
				if !e.IsDir() {
					if info, ierr := e.Info(); ierr == nil && info.ModTime().Before(cutoff) {
						return fmt.Errorf("derived preprocessing audio remains: %s", filepath.Join(cfg.Paths.AudioWork, e.Name()))
					}
				}
			}
		}

		var blobCount int
		_ = db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks WHERE typeof(temporary_path)='blob' OR typeof(transcript_sha256)='blob'`).Scan(&blobCount)
		if blobCount > 0 {
			return errors.New("audio chunk metadata contains an unexpected BLOB")
		}

		var badImports int
		_ = db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM imports WHERE state='completed' AND temporary_path IS NOT NULL`).Scan(&badImports)
		if badImports > 0 {
			return fmt.Errorf("%d completed imports still reference source audio", badImports)
		}

		refImports := map[string]bool{}
		for _, q := range []string{`SELECT temporary_path FROM imports WHERE temporary_path IS NOT NULL`, `SELECT temporary_path FROM import_parts WHERE temporary_path IS NOT NULL`} {
			r2, _ := db.R.QueryContext(ctx, q)
			if r2 != nil {
				for r2.Next() {
					var p string
					if r2.Scan(&p) == nil {
						refImports[p] = true
					}
				}
				r2.Close()
			}
		}
		if ents, rerr := os.ReadDir(cfg.Paths.ImportTmp); rerr == nil {
			for _, e := range ents {
				if !e.IsDir() {
					p := filepath.Join(cfg.Paths.ImportTmp, e.Name())
					if !refImports[p] {
						return fmt.Errorf("unreferenced import audio remains: %s", p)
					}
				}
			}
		}

		var terminal int
		_ = db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM audio_chunks WHERE state IN ('transcribed','silent')`).Scan(&terminal)
		fmt.Fprintf(m.Out, "Verified %d terminal chunks; no original recording chunks or unreferenced temporary audio were found.\n", terminal)
		return nil
	})
}

func (m *Manager) cmdChannel(_ context.Context, args []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := m.ensureDefaultEnvFile(cfg); err != nil {
		return err
	}
	uSvc := &updates.Service{Cfg: func() config.Config { return cfg }, AppDir: cfg.AppDir, CurrentVersion: m.Version}
	if len(args) == 0 {
		ch := uSvc.Channel()
		m.UI.Info(fmt.Sprintf("Release channel: %s", release.ChannelLabel(ch)))
		return nil
	}
	ch := release.ParseChannel(args[0])
	if ch == "" {
		return errors.New("usage: neorecall channel [stable|beta]")
	}
	if err := envfile.Upsert(cfg.Paths.EnvFile, "NEORECALL_RELEASE_CHANNEL", ch); err != nil {
		return err
	}
	m.UI.OK(fmt.Sprintf("Release channel set to %s.", release.ChannelLabel(ch)))
	return nil
}

// printUpdateNotes is `update --notes`: what is waiting, in words.
func (m *Manager) printUpdateNotes(status map[string]any) error {
	if failed, _ := status["checkFailed"].(bool); failed {
		return errors.New("NeoRecall couldn't reach GitHub to look for updates; check the internet connection and try again")
	}
	current, _ := status["version"].(string)
	available, _ := status["available"].(map[string]any)
	version, _ := available["version"].(string)
	if version == "" {
		m.UI.OK(fmt.Sprintf("You have the latest version (%s)", current))
		return nil
	}
	m.UI.OK(fmt.Sprintf("%s is ready; you have %s. Get it with neorecall update.", version, current))
	return nil
}

func (m *Manager) cmdUpdate(ctx context.Context, args []string) error {
	// A mistyped flag must never fall through to a real update.
	requested := ""
	for _, arg := range args {
		switch arg {
		case "--notes", "--check", "--json", "--details", "--quiet", "--apply", "--force", "--refresh-web":
		default:
			if requested != "" || release.ParseChannel(arg) == "" {
				return errors.New("usage: neorecall update [stable|beta] [--notes|--check] [--json]")
			}
			requested = release.ParseChannel(arg)
		}
	}
	readOnly := cli.HasFlag(args, "--notes") || cli.HasFlag(args, "--check") || cli.HasFlag(args, "--json")
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if cfg.ContainerImage {
		return errors.New("this NeoRecall runs in a container image; update by pulling the newer image and restarting the container")
	}
	uSvc := &updates.Service{Cfg: func() config.Config { return cfg }, AppDir: cfg.AppDir, CurrentVersion: m.Version}
	applyMode := cli.HasFlag(args, "--apply")
	var jobSt updates.UpdateStatusFile
	if applyMode {
		jobSt = uSvc.ReadJobStatus()
		if jobSt.State != "running" {
			now := timeutil.NowISO()
			vBef := strings.TrimPrefix(m.Version, "v")
			jobSt = updates.UpdateStatusFile{
				State: "running", Phase: "starting", Progress: 5, Message: "Checking for updates",
				StartedAt: &now, VersionBefore: &vBef, Changelog: []string{}, Logs: []string{},
			}
			uSvc.WriteJobStatus(jobSt)
		}
	}
	recordJob := func(phase string, progress int, msg string, state string, verAfter string, rolledBack bool) {
		if !applyMode {
			return
		}
		jobSt.Phase = phase
		jobSt.Progress = progress
		jobSt.Message = msg
		jobSt.Logs = append(jobSt.Logs, msg)
		if state != "" {
			jobSt.State = state
		}
		if verAfter != "" {
			jobSt.VersionAfter = &verAfter
		}
		jobSt.RolledBack = rolledBack
		if state == "completed" || state == "failed" {
			done := timeutil.NowISO()
			jobSt.CompletedAt = &done
		}
		uSvc.WriteJobStatus(jobSt)
	}
	failJob := func(err error, rolledBack bool) error {
		if err != nil {
			recordJob("failed", 100, err.Error(), "failed", "", rolledBack)
		}
		return err
	}

	if readOnly {
		// Look at the requested channel for this run only; nothing is saved.
		if requested != "" {
			if err := os.Setenv("NEORECALL_RELEASE_CHANNEL", requested); err != nil {
				return err
			}
		}
		chk := uSvc.Check()
		if cli.HasFlag(args, "--notes") && !cli.HasFlag(args, "--json") {
			return m.printUpdateNotes(chk)
		}
		b, _ := json.MarshalIndent(chk, "", "  ")
		fmt.Fprintln(m.Out, string(b))
		return nil
	}
	if requested != "" {
		if _, serr := uSvc.SetChannel(requested); serr != nil {
			return failJob(serr, false)
		}
		cfg, _ = m.loadConfig()
	}

	// If an earlier install left an unmigrated Node.js DB/service behind, finish migrating it before restarting.
	legacy := InspectLegacyJS(cfg, m.UserHome, m.Getenv)
	if legacy.NeedsMigration {
		sm, _ := m.serviceManager(cfg)
		m.stopRunningProcesses(cfg, sm)
		bk, merr := m.migrateLegacyJSState(ctx, cfg, legacy)
		if merr != nil {
			return failJob(merr, false)
		}
		_ = WriteMigratedMarker(cfg, m.Version, bk, "migrated during update")
		m.RestartAfterLegacyMigration = true
		cfg, _ = m.loadConfig()
	}

	channel := uSvc.Channel()
	recordJob("checking", 15, "Checking latest "+channel+" release on GitHub", "running", "", false)
	rel, err := fetchLatestReleaseFrom(ctx, m.HTTP, channel, m.releaseAPIBase())
	if err != nil {
		return failJob(err, false)
	}
	targetVer := strings.TrimPrefix(rel.TagName, "v")
	curVer := strings.TrimPrefix(m.Version, "v")
	if active, err := runtimeStore(cfg).Current(); err == nil {
		curVer = active.Version
	}
	_, webStatErr := os.Stat(filepath.Join(cfg.WebDir, "index.html"))

	if release.CompareVersions(targetVer, curVer) <= 0 && !cli.HasFlag(args, "--force") {
		if cli.HasFlag(args, "--refresh-web") || webStatErr != nil {
			if _, werr := m.ensureStandaloneWebBundle(ctx, cfg, channel, true); werr != nil {
				m.UI.Warn("Web UI bundle refresh skipped: " + werr.Error())
			}
		}
		recordJob("completed", 100, "NeoRecall is up to date ("+curVer+" on "+channel+").", "completed", curVer, false)
		update.UpToDate(m.UI, curVer, channel)
		return nil
	}
	if hasSignedRuntime(rel, targetVer) {
		recordJob("downloading", 35, "Downloading verified runtime "+targetVer, "running", "", false)
		rolledBack, err := m.updateSignedRuntime(ctx, cfg, rel, curVer, targetVer)
		m.RestartAfterLegacyMigration = false
		if err != nil {
			return failJob(err, rolledBack)
		}
		recordJob("completed", 100, "Updated NeoRecall to "+targetVer+".", "completed", targetVer, false)
		return nil
	}
	return failJob(errors.New("the selected release does not contain a signed runtime manifest"), false)
}

func (m *Manager) waitForServerVersion(ctx context.Context, port int, version string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		if health, ok := fetchJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/health", port)); ok {
			if got, _ := health["version"].(string); strings.TrimPrefix(got, "v") == version {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("NeoRecall did not report version %s on port %d", version, port)
		case <-tick.C:
		}
	}
}

func (m *Manager) cmdEnv(_ context.Context, args []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if err := m.ensureDefaultEnvFile(cfg); err != nil {
		return err
	}
	sub := ""
	if len(args) > 0 {
		sub = strings.ToLower(strings.TrimSpace(args[0]))
	}
	switch sub {
	case "", "list":
		vals, err := envfile.Load(cfg.Paths.EnvFile)
		if err != nil {
			return err
		}
		for _, k := range envfile.SortedKeys(vals) {
			fmt.Fprintf(m.Out, "%s=%s\n", k, envfile.Mask(k, vals[k]))
		}
		return nil
	case "get":
		if len(args) < 2 {
			return errors.New("usage: neorecall env get <KEY>")
		}
		vals, err := envfile.Load(cfg.Paths.EnvFile)
		if err != nil {
			return err
		}
		v, ok := vals[args[1]]
		if !ok {
			return fmt.Errorf("key not found: %s", args[1])
		}
		fmt.Fprintln(m.Out, v)
		return nil
	case "set":
		if len(args) < 3 {
			return errors.New("usage: neorecall env set <KEY> <VALUE>")
		}
		key := args[1]
		val := strings.Join(args[2:], " ")
		if err := envfile.Upsert(cfg.Paths.EnvFile, key, val); err != nil {
			return err
		}
		m.UI.OK("Saved " + key)
		return nil
	case "unset":
		if len(args) < 2 {
			return errors.New("usage: neorecall env unset <KEY>")
		}
		removed, err := envfile.Remove(cfg.Paths.EnvFile, args[1])
		if err != nil {
			return err
		}
		if !removed {
			m.UI.Warn(args[1] + " was not set.")
		} else {
			m.UI.OK("Removed " + args[1])
		}
		return nil
	default:
		return errors.New("usage: neorecall env [list|get|set|unset] ...")
	}
}

func (m *Manager) cmdAdmin(ctx context.Context, args []string) error {
	jsonOut := cli.HasFlag(args, "--json")
	pos := cli.Positionals(args)
	sub := "list"
	var username string
	if len(pos) > 0 {
		sub = pos[0]
	}
	if len(pos) > 1 {
		username = pos[1]
	}
	if sub != "list" && sub != "grant" && sub != "revoke" {
		return errors.New("usage: neorecall admin [list | grant <username> | revoke <username>] [--json]")
	}
	if sub != "list" && username == "" {
		return fmt.Errorf("usage: neorecall admin %s <username>", sub)
	}
	return m.withDB(ctx, func(ctx context.Context, db *dbx.DB, cfg config.Config) error {
		keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
		aSvc := &auth.Service{DB: db, Cfg: func() config.Config { return cfg }, MasterKey: keyFn, RemoveIndex: embeddings.RemoveForUserTx}
		if sub == "list" {
			admins, err := aSvc.ListAdmins(ctx)
			if err != nil {
				return err
			}
			names := make([]string, len(admins))
			for i, a := range admins {
				names[i] = a.Username
			}
			if jsonOut {
				b, _ := json.Marshal(map[string]any{"admins": names})
				fmt.Fprintln(m.Out, string(b))
				return nil
			}
			if len(names) == 0 {
				m.UI.Info("No admins configured yet.")
				return nil
			}
			for _, n := range names {
				m.UI.OK(n)
			}
			return nil
		}
		var res auth.AdminChange
		var err error
		if sub == "grant" {
			res, err = aSvc.GrantAdmin(ctx, username, "cli")
		} else {
			res, err = aSvc.RevokeAdmin(ctx, username, "cli")
		}
		if err != nil {
			return err
		}
		if jsonOut {
			b, _ := json.Marshal(res)
			fmt.Fprintln(m.Out, string(b))
			return nil
		}
		if !res.Changed {
			m.UI.Info(fmt.Sprintf("%s role unchanged.", res.Username))
		} else {
			m.UI.OK(fmt.Sprintf("Updated admin role for %s.", res.Username))
		}
		return nil
	})
}

func (m *Manager) cmdAccount(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "create" {
		return errors.New("usage: neorecall account create --username <name> --password <password> [--email <email>] [--admin]")
	}
	rest := args[1:]
	username, _ := cli.FlagValue(rest, "--username")
	password, _ := cli.FlagValue(rest, "--password")
	emailRaw, hasEmail := cli.FlagValue(rest, "--email")
	wantAdmin := cli.HasFlag(rest, "--admin")
	if username == "" || password == "" {
		return errors.New("usage: neorecall account create --username <name> --password <password> [--email <email>] [--admin]")
	}
	var emailPtr *string
	if hasEmail && strings.TrimSpace(emailRaw) != "" {
		emailPtr = &emailRaw
	}
	return m.withDB(ctx, func(ctx context.Context, db *dbx.DB, cfg config.Config) error {
		cfg.RegistrationEnabled = true
		keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
		aSvc := &auth.Service{DB: db, Cfg: func() config.Config { return cfg }, MasterKey: keyFn, RemoveIndex: embeddings.RemoveForUserTx}
		u, _, err := aSvc.Register(ctx, username, emailPtr, password, auth.RequestContext{IPAddress: "127.0.0.1"})
		if err != nil {
			return err
		}
		if wantAdmin && u.Role != "admin" {
			if _, gerr := aSvc.GrantAdmin(ctx, u.Username, "cli"); gerr != nil {
				return gerr
			}
			u.Role = "admin"
		}
		fmt.Fprintf(m.Out, "Created user %s (id=%s, role=%s)\n", u.Username, u.ID, u.Role)
		return nil
	})
}

func (m *Manager) cmdResetPassword(ctx context.Context, args []string) error {
	passFile, hasFile := cli.FlagValue(args, "--password-file")
	pos := cli.Positionals(args, "--password-file")
	if len(pos) == 0 {
		return errors.New("usage: neorecall reset-password <username-or-email> [--password-file PATH]")
	}
	account := pos[0]
	var pw string
	if hasFile {
		b, err := os.ReadFile(passFile)
		if err != nil {
			return err
		}
		pw = strings.TrimRight(string(b), "\r\n")
	} else if len(pos) > 1 {
		pw = pos[1]
	} else if m.UI.Interactive() {
		var err error
		pw, err = m.UI.AskSecret("New password", "")
		if err != nil {
			return err
		}
	} else {
		br := bufio.NewReader(m.In)
		line, _ := br.ReadString('\n')
		pw = strings.TrimRight(line, "\r\n")
	}
	return m.withDB(ctx, func(ctx context.Context, db *dbx.DB, _ config.Config) error {
		var id, uname string
		err := db.R.QueryRowContext(ctx, `SELECT id, username FROM users WHERE username=? COLLATE NOCASE OR email=? COLLATE NOCASE`, account, account).Scan(&id, &uname)
		if errors.Is(err, sql.ErrNoRows) {
			return errors.New("user not found")
		}
		if err != nil {
			return err
		}
		// The same policy and sign-out as a password changed in the app.
		if err := auth.NewService(db, m.configOrZero, nil).SetPassword(ctx, id, pw); err != nil {
			return err
		}
		m.UI.OK(fmt.Sprintf("New password set for %s; existing sessions revoked.", uname))
		return nil
	})
}

func (m *Manager) cmdBackup(ctx context.Context, args []string) error {
	return m.withDB(ctx, func(ctx context.Context, db *dbx.DB, cfg config.Config) error {
		keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
		bSvc := &backup.Service{DB: db, Cfg: func() config.Config { return cfg }, MasterKey: keyFn}
		if len(args) > 0 && args[0] == "list" {
			st, err := bSvc.Status()
			if err != nil {
				return err
			}
			b, _ := json.MarshalIndent(st, "", "  ")
			fmt.Fprintln(m.Out, string(b))
			return nil
		}
		art, err := bSvc.Create(ctx)
		if err != nil {
			return err
		}
		m.UI.OK(fmt.Sprintf("Backup created: %s (%d bytes)", art.Key, art.Bytes))
		return nil
	})
}

func (m *Manager) cmdRestore(ctx context.Context, args []string) error {
	outFlag, hasOut := cli.FlagValue(args, "--output")
	pos := cli.Positionals(args, "--output")
	if len(pos) == 0 {
		return errors.New("usage: neorecall restore <artifact-key> [--output PATH]")
	}
	keyName := pos[0]
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	if b, err := os.ReadFile(cfg.Paths.PIDFile); err == nil {
		if pid, perr := strconv.Atoi(strings.TrimSpace(string(b))); perr == nil && pid > 0 {
			if p, ferr := os.FindProcess(pid); ferr == nil {
				// Signal 0 probe via kill -0 equivalent handled by service stop recommendation.
				_ = p
			}
		}
	}
	output := outFlag
	if !hasOut || output == "" {
		cleanKey := strings.TrimSuffix(filepath.Base(keyName), ".nrbak")
		output = filepath.Join(filepath.Dir(cfg.Paths.Database), "restored-"+cleanKey+".sqlite3")
	}
	absOut, err := filepath.Abs(output)
	if err != nil {
		return err
	}
	absDB, _ := filepath.Abs(cfg.Paths.Database)
	if absOut == absDB {
		return errors.New("refusing to write directly over the live database; restore beside it first")
	}
	if _, err := os.Stat(absOut); err == nil {
		return fmt.Errorf("%s already exists; pass a different --output", absOut)
	}

	bSvc := &backup.Service{Cfg: func() config.Config { return cfg }, MasterKey: func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }}
	dst, err := bSvc.Destination()
	if err != nil {
		return err
	}
	tmpEnc := absOut + ".enc.tmp"
	if err := dst.Fetch(keyName, tmpEnc); err != nil {
		return err
	}
	defer os.Remove(tmpEnc)

	key, err := crypto.MasterKey(cfg.Paths.SecretKey)
	if err != nil {
		return err
	}
	if err := backup.RestoreFile(key, tmpEnc, absOut); err != nil {
		return err
	}
	m.UI.OK(fmt.Sprintf("Restored verified database to %s", absOut))
	return nil
}

func (m *Manager) cmdRebuildWeb(ctx context.Context, _ []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	flDir := filepath.Join(cfg.AppDir, "flutter_app")
	if _, err := os.Stat(flDir); err != nil {
		return fmt.Errorf("flutter_app directory not found in %s", cfg.AppDir)
	}
	cmd := exec.CommandContext(ctx, "flutter", "build", "web", "--release")
	cmd.Dir = flDir
	cmd.Stdout = m.Out
	cmd.Stderr = m.Err
	return cmd.Run()
}

func (m *Manager) cmdUninstall(ctx context.Context, _ []string) error {
	cfg, err := m.loadConfig()
	if err != nil {
		return err
	}
	_ = m.cmdStop(ctx, nil)
	sm, err := m.serviceManager(cfg)
	if err != nil {
		return err
	}
	sm.Uninstall()
	m.UI.OK("NeoRecall startup service removed; your data remains in " + cfg.Paths.Home)
	return nil
}

// Keep unused archive/gzip helper unused-warning free when tar.gz bundles are later unpacked by update.
var (
	_ = tar.ErrHeader
	_ = gzip.ErrHeader
)

func (m *Manager) configOrZero() config.Config {
	cfg, _ := m.loadConfig()
	return cfg
}
