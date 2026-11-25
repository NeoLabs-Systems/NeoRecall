package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNextVersionForTagsAndSetVersion(t *testing.T) {
	got, err := NextVersionForTags("0.1.4-beta.7", []string{"v0.1.4-beta.6", "v0.1.4-beta.7"}, "beta")
	if err != nil || got != "0.1.4-beta.8" {
		t.Fatalf("beta next: got %q (%v)", got, err)
	}
	got, err = NextVersionForTags("0.1.4-beta.7", []string{"v0.1.3", "v0.1.4-beta.7"}, "stable")
	if err != nil || got != "0.1.4" {
		t.Fatalf("stable next: got %q (%v)", got, err)
	}
	got, err = NextVersionForTags("0.1.0-dev", []string{"v0.1.4"}, "beta")
	if err != nil || got != "0.1.5-beta.0" {
		t.Fatalf("beta after stable: got %q (%v)", got, err)
	}

	root := t.TempDir()
	cfgPath := filepath.Join(root, "internal", "config", "config.go")
	if err := os.MkdirAll(filepath.Dir(cfgPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, []byte("package config\nconst (\n\tVersion = \"0.1.4-beta.7\"\n)\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SetVersion(root, "v0.1.4-beta.8"); err != nil {
		t.Fatal(err)
	}
	v, err := ReadVersion(root)
	if err != nil || v != "0.1.4-beta.8" {
		t.Fatalf("ReadVersion: got %q (%v)", v, err)
	}
}

func TestDownloadNotesAndMerge(t *testing.T) {
	sec := DownloadNotes("v0.1.4-beta.8", "NeoLabs-Systems/NeoRecall", []ReleaseAsset{
		{Name: "NeoRecall-macOS-0.1.4-beta.8.dmg"},
		{Name: "NeoRecall-Android-0.1.4-beta.8.apk"},
	})
	if !strings.Contains(sec, "NeoRecall-macOS-0.1.4-beta.8.dmg") || !strings.Contains(sec, "building") {
		t.Fatalf("unexpected download notes:\n%s", sec)
	}
	merged := MergeDownloadNotes(notesStart+"\nold\n"+notesEnd+"\n\n## Changes", sec)
	if !strings.Contains(merged, "## Changes") || strings.Contains(merged, "\nold\n") {
		t.Fatalf("merge failed:\n%s", merged)
	}
}
