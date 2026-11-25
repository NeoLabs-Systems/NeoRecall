// Command neorecall-release is the release tooling CI runs: resolving and
// bumping semantic versions in internal/config/config.go and rendering the
// shields.io download badge section in GitHub release notes.
//
//	go run ./cmd/neorecall-release <command> [flags]
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	defaultRepo = "NeoLabs-Systems/NeoRecall"
	configFile  = "internal/config/config.go"
	notesStart  = "<!-- neorecall-download:start -->"
	notesEnd    = "<!-- neorecall-download:end -->"
)

var (
	versionPattern   = regexp.MustCompile(`^\d+\.\d+\.\d+(-beta\.\d+)?$`)
	goVersionLine    = regexp.MustCompile(`(Version\s*=\s*)"[^"]*"`)
	stableTagPattern = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)$`)
	betaTagPattern   = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)-beta\.(\d+)$`)
)

type appSlot struct {
	id, label, detail, badgeLabel, badgeMessage, badgeLogo, readyColor string
	pattern                                                            *regexp.Regexp
}

var appSlots = []appSlot{
	{"macos", "macOS", "app", "macOS", "dmg", "apple", "1c2117", regexp.MustCompile(`^NeoRecall-macOS-.+\.dmg$`)},
	{"windows-x64", "Windows", "x64", "Windows", "x64", "windows", "0078d4", regexp.MustCompile(`^NeoRecall-Windows-x64-.+\.zip$`)},
	{"android", "Android", "APK", "Android", "APK", "android", "3ddc84", regexp.MustCompile(`^NeoRecall-Android-.+\.apk$`)},
	{"wearos", "Wear OS", "APK", "Wear OS", "APK", "wearos", "4285f4", regexp.MustCompile(`^NeoRecall-WearOS-.+\.apk$`)},
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "neorecall-release:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: neorecall-release <version|resolve-version|set-version|release-download> [flags]")
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	channel := fs.String("channel", "beta", "")
	ghOut := fs.Bool("github-output", false, "")
	tag := fs.String("tag", "", "")
	repo := fs.String("repo", "", "")
	dryRun := fs.Bool("dry-run", false, "")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	switch args[0] {
	case "version":
		v, err := ReadVersion(".")
		if err != nil {
			return err
		}
		fmt.Println(v)
	case "resolve-version":
		v, err := ResolveNextVersion(ctx, ".", *channel)
		if err != nil {
			return err
		}
		if *ghOut {
			if outPath := os.Getenv("GITHUB_OUTPUT"); outPath != "" {
				f, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
				if err != nil {
					return err
				}
				_, werr := fmt.Fprintf(f, "version=%s\nrelease_tag=v%s\n", v, v)
				_ = f.Close()
				if werr != nil {
					return werr
				}
			}
		}
		fmt.Println(v)
	case "set-version":
		if fs.NArg() != 1 {
			return errors.New("usage: neorecall-release set-version VERSION")
		}
		return SetVersion(".", fs.Arg(0))
	case "release-download":
		if strings.TrimSpace(*tag) == "" {
			return errors.New("--tag is required")
		}
		repository := strings.TrimSpace(*repo)
		if repository == "" {
			repository = strings.TrimSpace(os.Getenv("GITHUB_REPOSITORY"))
		}
		if repository == "" {
			repository = defaultRepo
		}
		changed, body, err := UpdateDownloadNotes(ctx, *tag, repository, *dryRun)
		if err != nil {
			return err
		}
		if *dryRun {
			fmt.Print(body)
		} else if !changed {
			fmt.Println("Release notes already current.")
		}
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
	return nil
}

// ReadVersion reads config.Version from internal/config/config.go under root.
func ReadVersion(root string) (string, error) {
	b, err := os.ReadFile(filepath.Join(root, configFile))
	if err != nil {
		return "", err
	}
	m := regexp.MustCompile(`Version\s*=\s*"([^"]+)"`).FindSubmatch(b)
	if len(m) < 2 {
		return "", fmt.Errorf("version constant not found in %s", configFile)
	}
	return strings.TrimSpace(string(m[1])), nil
}

// SetVersion validates and writes version into internal/config/config.go.
func SetVersion(root, version string) error {
	version = strings.TrimPrefix(strings.TrimSpace(version), "v")
	if !versionPattern.MatchString(version) {
		return fmt.Errorf("invalid version %q: want MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N", version)
	}
	p := filepath.Join(root, configFile)
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	if !goVersionLine.Match(b) {
		return fmt.Errorf("version constant not found in %s", p)
	}
	next := goVersionLine.ReplaceAll(b, []byte(`${1}"`+version+`"`))
	return os.WriteFile(p, next, 0o644)
}

type semTriplet struct{ major, minor, patch int }

func parseTriplet(s string) (semTriplet, bool) {
	base := strings.SplitN(strings.TrimPrefix(strings.TrimSpace(s), "v"), "-", 2)[0]
	parts := strings.Split(base, ".")
	if len(parts) != 3 {
		return semTriplet{}, false
	}
	maj, e1 := strconv.Atoi(parts[0])
	min, e2 := strconv.Atoi(parts[1])
	pat, e3 := strconv.Atoi(parts[2])
	if e1 != nil || e2 != nil || e3 != nil {
		return semTriplet{}, false
	}
	return semTriplet{maj, min, pat}, true
}

func maxTriplet(a, b semTriplet) semTriplet {
	if a.major != b.major {
		if a.major > b.major {
			return a
		}
		return b
	}
	if a.minor != b.minor {
		if a.minor > b.minor {
			return a
		}
		return b
	}
	if a.patch >= b.patch {
		return a
	}
	return b
}

// ResolveNextVersion computes the next release version from config.Version and git tags.
func ResolveNextVersion(ctx context.Context, root, channel string) (string, error) {
	fileVer, err := ReadVersion(root)
	if err != nil {
		fileVer = "0.1.0"
	}
	cmd := exec.CommandContext(ctx, "git", "tag", "--list", "v[0-9]*.[0-9]*.[0-9]*")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("list git tags: %w", err)
	}
	tags := strings.Fields(string(out))
	return NextVersionForTags(fileVer, tags, channel)
}

// NextVersionForTags computes the next beta or stable semver string cleanly.
func NextVersionForTags(fileVer string, tags []string, channel string) (string, error) {
	fileBase, ok := parseTriplet(fileVer)
	if !ok {
		fileBase = semTriplet{0, 1, 0}
	}
	var latestStable semTriplet
	hasStable := false
	for _, t := range tags {
		if m := stableTagPattern.FindStringSubmatch(t); len(m) == 4 {
			if tr, ok := parseTriplet(t); ok {
				if !hasStable {
					latestStable = tr
					hasStable = true
				} else {
					latestStable = maxTriplet(latestStable, tr)
				}
			}
		}
	}
	stableNext := semTriplet{0, 0, 1}
	if hasStable {
		stableNext = semTriplet{latestStable.major, latestStable.minor, latestStable.patch + 1}
	}
	base := maxTriplet(fileBase, stableNext)
	baseStr := fmt.Sprintf("%d.%d.%d", base.major, base.minor, base.patch)
	if strings.EqualFold(strings.TrimSpace(channel), "stable") {
		return baseStr, nil
	}
	if !strings.EqualFold(strings.TrimSpace(channel), "beta") {
		return "", fmt.Errorf("unknown channel %q: want beta or stable", channel)
	}
	var betaNums []int
	for _, t := range tags {
		if m := betaTagPattern.FindStringSubmatch(t); len(m) == 5 {
			tBase := fmt.Sprintf("%s.%s.%s", m[1], m[2], m[3])
			if tBase == baseStr {
				if n, err := strconv.Atoi(m[4]); err == nil {
					betaNums = append(betaNums, n)
				}
			}
		}
	}
	nextBeta := 0
	if len(betaNums) > 0 {
		sort.Ints(betaNums)
		nextBeta = betaNums[len(betaNums)-1] + 1
	}
	return fmt.Sprintf("%s-beta.%d", baseStr, nextBeta), nil
}

type ReleaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

func encodeURIComponent(s string) string {
	return strings.NewReplacer("+", "%20", "%21", "!", "%27", "'", "%28", "(", "%29", ")", "%2A", "*", "%7E", "~").Replace(url.QueryEscape(s))
}

func badge(label, message, color, logo string) string {
	return "https://img.shields.io/badge/" + encodeURIComponent(label) + "-" + encodeURIComponent(message) + "-" + color +
		"?style=for-the-badge&logo=" + encodeURIComponent(logo) + "&logoColor=white"
}

// DownloadNotes renders the download badge header for a NeoRecall GitHub release.
func DownloadNotes(tag, repository string, assets []ReleaseAsset) string {
	if repository = strings.TrimSpace(repository); repository == "" {
		repository = defaultRepo
	}
	ready := map[string]string{}
	for _, a := range assets {
		for _, s := range appSlots {
			if s.pattern.MatchString(a.Name) {
				u := a.URL
				if u == "" {
					u = fmt.Sprintf("https://github.com/%s/releases/download/%s/%s", repository, encodeURIComponent(tag), encodeURIComponent(a.Name))
				}
				ready[s.id] = u
				break
			}
		}
	}
	releaseURL := fmt.Sprintf("https://github.com/%s/releases/tag/%s", repository, encodeURIComponent(tag))
	var badges []string
	for _, s := range appSlots {
		href, color, message := releaseURL, "6b7280", "building"
		if u, ok := ready[s.id]; ok {
			href, color, message = u, s.readyColor, s.badgeMessage
		}
		badges = append(badges, fmt.Sprintf(`<a href="%s"><img alt="%s %s" src="%s"></a>`, href, s.label, s.detail, badge(s.badgeLabel, message, color, s.badgeLogo)))
	}
	status := "Every app for this release is ready."
	switch {
	case len(ready) == 0:
		status = "The apps are building now. Each one appears here as soon as its build finishes."
	case len(ready) < len(appSlots):
		status = "Ready apps download in one click. The rest attach as soon as their builds finish."
	}
	return strings.Join([]string{
		notesStart, "", `<p align="center">`, "  <strong>Download NeoRecall " + tag + "</strong>", "</p>", "",
		`<p align="center">`, "  " + strings.Join(badges, "\n  "), "</p>", "",
		`<p align="center"><sub>` + status + `</sub></p>`, "", "---", "", notesEnd,
	}, "\n")
}

// MergeDownloadNotes replaces the download section in body, or prepends it.
func MergeDownloadNotes(body, section string) string {
	current := strings.TrimPrefix(body, "\uFEFF")
	section = strings.TrimSpace(section)
	if section == "" {
		return current
	}
	start, end := strings.Index(current, notesStart), strings.Index(current, notesEnd)
	if start >= 0 && end > start {
		before := strings.TrimRight(current[:start], " \t\r\n")
		after := strings.TrimLeft(current[end+len(notesEnd):], " \t\r\n")
		var parts []string
		for _, p := range []string{before, section, after} {
			if p != "" {
				parts = append(parts, p)
			}
		}
		return strings.TrimSpace(strings.Join(parts, "\n\n")) + "\n"
	}
	if strings.TrimSpace(current) == "" {
		return section + "\n"
	}
	return section + "\n\n" + strings.TrimLeft(current, " \t\r\n")
}

// UpdateDownloadNotes updates the download section of a draft or published release.
func UpdateDownloadNotes(ctx context.Context, tag, repository string, dryRun bool) (bool, string, error) {
	// `gh release view` works on drafts too, unlike the tags endpoint.
	out, err := exec.CommandContext(ctx, "gh", "release", "view", tag, "--repo", repository, "--json", "body,assets").Output()
	if err != nil {
		return false, "", fmt.Errorf("gh release view: %w", err)
	}
	var rel struct {
		Body   string `json:"body"`
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(out, &rel); err != nil {
		return false, "", err
	}
	assets := make([]ReleaseAsset, 0, len(rel.Assets))
	for _, a := range rel.Assets {
		assets = append(assets, ReleaseAsset{Name: a.Name, URL: a.URL})
	}
	next := MergeDownloadNotes(rel.Body, DownloadNotes(tag, repository, assets))
	if next == strings.TrimSpace(strings.TrimPrefix(rel.Body, "\uFEFF"))+"\n" {
		return false, next, nil
	}
	if dryRun {
		return true, next, nil
	}
	notes := filepath.Join(os.TempDir(), "neorecall-release-notes-"+strconv.Itoa(os.Getpid())+".md")
	if err := os.WriteFile(notes, []byte(next), 0o600); err != nil {
		return false, "", err
	}
	defer os.Remove(notes)
	cmd := exec.CommandContext(ctx, "gh", "release", "edit", tag, "--repo", repository, "--notes-file", notes)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return true, next, cmd.Run()
}
