package runtimebundle

import (
	"archive/zip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
)

func TestBuildTarget(t *testing.T) {
	root, dist, stage := t.TempDir(), t.TempDir(), t.TempDir()
	for name, data := range map[string]string{"flutter_app/build/web/index.html": "web", "landing/index.html": "landing", "test/fixtures/sample.wav": "audio"} {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	target := targets[0]
	if err := os.WriteFile(filepath.Join(dist, target.binary), []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	var artifacts []release.Artifact
	if err := buildTarget(root, dist, stage, "1.0.0", target, &artifacts); err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].SizeBytes == 0 || len(artifacts[0].SHA256) != 64 {
		t.Fatalf("artifacts: %+v", artifacts)
	}
	archive, err := zip.OpenReader(filepath.Join(dist, artifacts[0].AssetName))
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	found := map[string]bool{}
	for _, f := range archive.File {
		found[f.Name] = true
	}
	for _, name := range []string{"app/bin/neorecall", "app/flutter_app/build/web/index.html", "app/landing/index.html", "app/test/fixtures/sample.wav"} {
		if !found[name] {
			t.Fatalf("missing %s", name)
		}
	}
}

func TestBuildSignsRuntimeManifest(t *testing.T) {
	root, dist := t.TempDir(), t.TempDir()
	for _, name := range []string{"flutter_app/build/web/index.html", "landing/index.html", "test/fixtures/sample.wav"} {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("asset"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, target := range targets {
		if err := os.WriteFile(filepath.Join(dist, target.binary), []byte("binary"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	if err := build(root, dist, "1.0.0", base64.StdEncoding.EncodeToString(der), base64.StdEncoding.EncodeToString(pub)); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dist, ManifestPrefix+"1.0.0.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sig, err := os.ReadFile(path + ".sig")
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := release.Verify(data, string(sig), base64.StdEncoding.EncodeToString(pub)); err != nil || !ok {
		t.Fatalf("signature valid=%v err=%v", ok, err)
	}
	var manifest release.RuntimeManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Artifacts) != len(targets) {
		t.Fatalf("artifacts: %+v", manifest.Artifacts)
	}
}
