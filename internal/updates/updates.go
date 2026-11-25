package updates

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/cli/envfile"
	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neolabs-go/llm/transport"
	"github.com/NeoLabs-Systems/neolabs-go/runtimecfg"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

const (
	CheckInterval     = 6 * time.Hour
	defaultGitHubRepo = "NeoLabs-Systems/NeoRecall"
)

var semverTagRe = regexp.MustCompile(`^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$`)

type UpdateStatusFile struct {
	State         string   `json:"state"`
	Phase         string   `json:"phase"`
	Progress      int      `json:"progress"`
	Message       string   `json:"message"`
	VersionBefore *string  `json:"versionBefore"`
	VersionAfter  *string  `json:"versionAfter"`
	Changelog     []string `json:"changelog"`
	RolledBack    bool     `json:"rolledBack"`
	Logs          []string `json:"logs"`
	StartedAt     *string  `json:"startedAt"`
	CompletedAt   *string  `json:"completedAt"`
	RunnerPID     *int     `json:"runnerPid,omitempty"`
}

type CheckInfo struct {
	CheckedAt *string
	Checked   bool
	Update    map[string]any
	Reason    string
	Channel   string
}

type Service struct {
	Cfg            func() config.Config
	AppDir         string
	CurrentVersion string
	HTTP           *http.Client
	ReleaseAPIBase string

	mu        sync.Mutex
	lastCheck CheckInfo
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) statusPath() string {
	if p := s.cfg().Paths.UpdateStatus; p != "" {
		return p
	}
	return filepath.Join(s.cfg().Paths.Home, "update-status.json")
}

func (s *Service) ReadJobStatus() UpdateStatusFile {
	raw, err := os.ReadFile(s.statusPath())
	if err != nil {
		return UpdateStatusFile{State: "idle", Phase: "idle", Changelog: []string{}, Logs: []string{}}
	}
	var st UpdateStatusFile
	if json.Unmarshal(raw, &st) != nil {
		return UpdateStatusFile{State: "idle", Phase: "idle", Changelog: []string{}, Logs: []string{}}
	}
	if st.Changelog == nil {
		st.Changelog = []string{}
	}
	if st.Logs == nil {
		st.Logs = []string{}
	}
	return st
}

func (s *Service) WriteJobStatus(st UpdateStatusFile) {
	jb, _ := json.MarshalIndent(st, "", "  ")
	_ = os.WriteFile(s.statusPath(), jb, 0o600)
}

func (s *Service) BlockedReason() *string {
	c := s.cfg()
	if c.ContainerImage || os.Getenv("container") != "" || fileExists("/.dockerenv") {
		r := "container"
		return &r
	}
	return nil
}

func (s *Service) Channel() string {
	ch := release.NormalizeChannel(os.Getenv("NEORECALL_RELEASE_CHANNEL"))
	if ch == "" && s.cfg().Paths.EnvFile != "" {
		if raw, err := os.ReadFile(s.cfg().Paths.EnvFile); err == nil {
			if v := runtimecfg.ParseEnv(string(raw))["NEORECALL_RELEASE_CHANNEL"]; v != "" {
				ch = release.NormalizeChannel(v)
			}
		}
	}
	if ch == "" {
		return "stable"
	}
	return ch
}

func (s *Service) Status() map[string]any {
	ch := s.Channel()
	job := s.ReadJobStatus()
	blocked := s.BlockedReason()
	s.mu.Lock()
	lc := s.lastCheck
	s.mu.Unlock()

	var checkedAt any
	var avail any
	checkFailed := false
	if lc.Channel == ch {
		if lc.CheckedAt != nil {
			checkedAt = *lc.CheckedAt
			checkFailed = !lc.Checked
		}
		if lc.Update != nil {
			if uv, _ := lc.Update["version"].(string); uv != "" && release.CompareVersions(uv, s.CurrentVersion) != 0 {
				avail = lc.Update
			}
		}
	}
	var ver any
	if s.CurrentVersion != "" {
		ver = s.CurrentVersion
	}
	return map[string]any{
		"version":       ver,
		"channel":       ch,
		"channelLabel":  release.ChannelLabel(ch),
		"selfUpdate":    blocked == nil,
		"blockedReason": blocked,
		"checkedAt":     checkedAt,
		"checkFailed":   checkFailed,
		"available":     avail,
		"job":           job,
	}
}

func (s *Service) httpClient() *http.Client {
	if s.HTTP != nil {
		return s.HTTP
	}
	return ssrf.NewClient(ssrf.Options{Timeout: 20 * time.Second})
}

func (s *Service) latestFromGitHub(channel string) (string, error) {
	base := strings.TrimRight(strings.TrimSpace(s.ReleaseAPIBase), "/")
	if base == "" {
		base = "https://api.github.com"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	res, err := transport.FetchText(ctx, s.httpClient(), transport.FetchOptions{
		Method:   http.MethodGet,
		URL:      base + "/repos/" + defaultGitHubRepo + "/releases?per_page=50",
		Header:   map[string]string{"Accept": "application/vnd.github+json"},
		MaxBytes: 4 << 20,
		Service:  "GitHub Releases",
		Timeout:  20 * time.Second,
	})
	if err != nil {
		return "", err
	}
	if !res.OK() {
		return "", httperr.New(res.Status, "GITHUB_RELEASES_FAILED", "Could not check GitHub releases.")
	}
	var all []struct {
		TagName    string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
	}
	if err := json.Unmarshal([]byte(res.Text), &all); err != nil {
		return "", err
	}
	best := ""
	for _, r := range all {
		if r.Draft || (channel != "beta" && r.Prerelease) || !semverTagRe.MatchString(r.TagName) {
			continue
		}
		v := strings.TrimPrefix(r.TagName, "v")
		if best == "" || release.CompareVersions(v, best) > 0 {
			best = v
		}
	}
	return best, nil
}

func (s *Service) Check() map[string]any {
	ch := s.Channel()
	if s.BlockedReason() != nil {
		return s.Status()
	}
	latestTag, err := s.latestFromGitHub(ch)
	if (err != nil || latestTag == "") && s.AppDir != "" && dirExists(filepath.Join(s.AppDir, ".git")) {
		cmd := exec.Command("git", "fetch", "origin", "--tags", "--force", "--quiet")
		cmd.Dir = s.AppDir
		if gerr := cmd.Run(); gerr == nil {
			out, _ := exec.Command("git", "-C", s.AppDir, "tag", "-l", "v*", "--sort=-v:refname").Output()
			for _, line := range strings.Split(string(out), "\n") {
				tag := strings.TrimSpace(line)
				if tag == "" || !semverTagRe.MatchString(tag) {
					continue
				}
				if ch == "stable" && strings.Contains(tag, "-") {
					continue
				}
				v := strings.TrimPrefix(tag, "v")
				if latestTag == "" || release.CompareVersions(v, latestTag) > 0 {
					latestTag = v
				}
			}
			err = nil
		}
	}
	now := timeutil.NowISO()
	if err != nil {
		s.mu.Lock()
		if !s.lastCheck.Checked || s.lastCheck.Channel != ch {
			s.lastCheck = CheckInfo{CheckedAt: &now, Checked: false, Channel: ch, Reason: err.Error()}
		}
		s.mu.Unlock()
		return s.Status()
	}
	var upd map[string]any
	if latestTag != "" && release.CompareVersions(latestTag, strings.TrimPrefix(s.CurrentVersion, "v")) > 0 {
		upd = map[string]any{"version": latestTag, "changes": []string{}}
	}
	s.mu.Lock()
	s.lastCheck = CheckInfo{CheckedAt: &now, Checked: true, Update: upd, Channel: ch}
	s.mu.Unlock()
	return s.Status()
}

func (s *Service) assertIdle() error {
	if r := s.BlockedReason(); r != nil {
		if *r == "container" {
			return httperr.New(http.StatusConflict, "UPDATE_CONTAINER", "NeoRecall runs from a container image. Pull the new image and recreate the container.")
		}
	}
	if s.ReadJobStatus().State == "running" {
		return httperr.New(http.StatusConflict, "UPDATE_RUNNING", "An update is already running.")
	}
	return nil
}

func (s *Service) SetChannel(requested string) (map[string]any, error) {
	if err := s.assertIdle(); err != nil {
		return nil, err
	}
	ch := release.ParseChannel(requested)
	if ch == "" {
		return nil, httperr.New(http.StatusBadRequest, "INVALID_CHANNEL", `The release channel must be "stable" or "beta".`)
	}
	_ = os.Setenv("NEORECALL_RELEASE_CHANNEL", ch)
	if envPath := s.cfg().Paths.EnvFile; envPath != "" {
		_ = envfile.Upsert(envPath, "NEORECALL_RELEASE_CHANNEL", ch)
	}
	return s.Check(), nil
}

func (s *Service) Start() (map[string]any, error) {
	if err := s.assertIdle(); err != nil {
		return nil, err
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	now := timeutil.NowISO()
	vBef := s.CurrentVersion
	st := UpdateStatusFile{
		State: "running", Phase: "starting", Progress: 1, Message: "Starting the update",
		StartedAt: &now, VersionBefore: &vBef, Changelog: []string{}, Logs: []string{},
	}
	s.WriteJobStatus(st)

	cmd := exec.Command(exe, "update", "--apply")
	cmd.Dir = s.AppDir
	if err := cmd.Start(); err != nil {
		done := timeutil.NowISO()
		st.State, st.Phase, st.Message, st.CompletedAt = "failed", "failed", "The update could not start: "+err.Error(), &done
		s.WriteJobStatus(st)
		return nil, err
	}
	pid := cmd.Process.Pid
	st.RunnerPID = &pid
	s.WriteJobStatus(st)
	_ = cmd.Process.Release()
	return s.Status(), nil
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}
