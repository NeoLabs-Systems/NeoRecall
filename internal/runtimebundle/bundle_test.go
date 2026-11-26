package runtimebundle

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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
	if err := buildTarget(context.Background(), root, dist, stage, "1.0.0", target, fakeNative, &artifacts); err != nil {
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
	for _, name := range []string{"app/bin/neorecall", "app/flutter_app/build/web/index.html", "app/landing/index.html", "app/test/fixtures/sample.wav", "app/bin/library"} {
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
	if err := build(context.Background(), root, dist, "1.0.0", base64.StdEncoding.EncodeToString(der), base64.StdEncoding.EncodeToString(pub), fakeNative); err != nil {
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

func fakeNative(_ context.Context, _, _, dir string) error {
	return os.WriteFile(filepath.Join(dir, "library"), []byte("native"), 0o755)
}

func TestEveryTargetHasPinnedNativeFiles(t *testing.T) {
	for _, target := range targets {
		n, err := nativeFor(target.platform, target.arch)
		if err != nil {
			t.Fatal(err)
		}
		for _, p := range []pin{n.libraries, n.ffmpeg, n.ffmpegLicense, n.ffmpegReadme} {
			if !strings.HasPrefix(p.url, "https://github.com/") || len(p.sha256) != 64 {
				t.Fatalf("%s-%s: bad pin %+v", target.platform, target.arch, p)
			}
		}
	}
}

func TestExtractLibrariesRequiresEveryName(t *testing.T) {
	var archive bytes.Buffer
	w := tar.NewWriter(&archive)
	if err := w.WriteHeader(&tar.Header{Name: "release/lib/one.so", Typeflag: tar.TypeReg, Size: 1, Mode: 0o644}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("1")); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	err := extractLibraries(tar.NewReader(&archive), []string{"one.so", "two.so"}, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "two.so") {
		t.Fatalf("err=%v", err)
	}
}
