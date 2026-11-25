package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNodeUpdaterHandsOver(t *testing.T) {
	node, errNode := exec.LookPath("node")
	_, errNpm := exec.LookPath("npm")
	if errNode != nil || errNpm != nil {
		t.Skip("node and npm are needed to replay the old updater")
	}
	t.Run("script", func(t *testing.T) {
		replayHandover(t, func(tree string) []string { return []string{node, filepath.Join(tree, "bin", "neorecall.js"), tree} })
	})
	t.Run("npm link", func(t *testing.T) {
		replayHandover(t, func(tree string) []string {
			link := filepath.Join(tree, "global", "bin", "neorecall")
			_ = os.MkdirAll(filepath.Dir(link), 0o755)
			if err := os.Symlink(filepath.Join(tree, "bin", "neorecall.js"), link); err != nil {
				t.Fatal(err)
			}
			return []string{node, link, "update", tree}
		})
	})
}

func replayHandover(t *testing.T, invoke func(tree string) []string) {
	t.Helper()
	tree := t.TempDir()
	copyInto := func(rel string) {
		raw, err := os.ReadFile(filepath.Join("..", "..", rel))
		if err != nil {
			t.Fatal(err)
		}
		_ = os.MkdirAll(filepath.Dir(filepath.Join(tree, rel)), 0o755)
		_ = os.WriteFile(filepath.Join(tree, rel), raw, 0o755)
	}
	for _, rel := range []string{"package.json", ".npmrc", "scripts/node-handover.sh"} {
		copyInto(rel)
	}
	marker := filepath.Join(t.TempDir(), "installed")
	_ = os.WriteFile(filepath.Join(tree, "install.sh"), []byte("#!/bin/bash\necho \"$NEORECALL_RELEASE_CHANNEL\" > '"+marker+"'\n"), 0o755)
	_ = os.MkdirAll(filepath.Join(tree, "node_modules", "kept"), 0o755)
	_ = os.WriteFile(filepath.Join(tree, "node_modules", "kept", "package.json"), []byte(`{"name":"kept","version":"1.0.0"}`), 0o644)
	_ = os.MkdirAll(filepath.Join(tree, "bin"), 0o755)
	_ = os.WriteFile(filepath.Join(tree, "bin", "neorecall.js"), []byte(`
const r = require('child_process').spawnSync('npm', ['install', '--omit=dev', '--no-audit', '--no-fund'], { cwd: process.argv[process.argv.length - 1], encoding: 'utf8' });
process.stdout.write(String(r.status) + '\n' + r.stderr);
`), 0o644)
	home := t.TempDir()
	env := append(os.Environ(), "HOME="+home, "NEORECALL_HOME="+filepath.Join(home, ".neorecall"))

	direct := exec.Command("npm", "install", "--no-audit", "--no-fund")
	direct.Dir, direct.Env = tree, env
	if out, err := direct.CombinedOutput(); err == nil || !strings.Contains(string(out), "no longer uses npm") {
		t.Fatalf("direct npm install: %v\n%s", err, out)
	}

	args := invoke(tree)
	updater := exec.Command(args[0], args[1:]...)
	updater.Env = env
	out, err := updater.CombinedOutput()
	if err != nil || !strings.HasPrefix(string(out), "1\n") || !strings.Contains(string(out), "switch then finishes by itself") {
		t.Fatalf("updater run: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(tree, "node_modules", "kept", "package.json")); err != nil {
		t.Fatal("npm pruned the old node_modules")
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if raw, err := os.ReadFile(marker); err == nil {
			if strings.TrimSpace(string(raw)) != "stable" {
				t.Fatalf("channel %q", raw)
			}
			log, _ := os.ReadFile(filepath.Join(home, ".neorecall", "data", "logs", "handover.log"))
			if !strings.Contains(string(log), "handing over to the Go binary") {
				t.Fatalf("log %q", log)
			}
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("install.sh never ran after the updater exited")
}
