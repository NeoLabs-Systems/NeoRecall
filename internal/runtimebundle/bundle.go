// Package runtimebundle packages NeoRecall's server, web assets and native
// code using the signed NeoLabs runtime manifest format.
package runtimebundle

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/cli/release"
	"github.com/NeoLabs-Systems/neorecall/internal/signing"
)

const ManifestPrefix = "neorecall-runtime-manifest-"

type target struct{ platform, arch, binary string }

var targets = []target{
	{"linux", "x64", "neorecall-cli-linux-x64"},
	{"linux", "arm64", "neorecall-cli-linux-arm64"},
	{"macos", "x64", "neorecall-cli-macos-x64"},
	{"macos", "arm64", "neorecall-cli-macos-arm64"},
	{"windows", "x64", "neorecall-cli-windows-x64.exe"},
}
var supported = release.Targets{"linux": {"x64", "arm64"}, "macos": {"x64", "arm64"}, "windows": {"x64"}}

// Build generates the same versioned, signed runtime format as NeoAgent.
func Build(ctx context.Context, root, dist, version, privateKey string) error {
	publicKey, err := signing.PublicKey()
	if err != nil {
		return err
	}
	return build(ctx, root, dist, version, privateKey, publicKey, fetchNative)
}

// nativeFetcher puts a target's native files into its bin directory.
type nativeFetcher func(ctx context.Context, platform, arch, dir string) error

func build(ctx context.Context, root, dist, version, privateKey, publicKey string, fetch nativeFetcher) error {
	version = strings.TrimPrefix(version, "v")
	if _, err := release.NormalizeVersion(version); err != nil {
		return err
	}
	if err := release.CheckKeypair(privateKey, publicKey); err != nil {
		return err
	}
	if err := os.MkdirAll(dist, 0o755); err != nil {
		return err
	}
	var artifacts []release.Artifact
	for _, t := range targets {
		stage, err := os.MkdirTemp("", "neorecall-runtime-")
		if err != nil {
			return err
		}
		err = buildTarget(ctx, root, dist, stage, version, t, fetch, &artifacts)
		cleanupErr := os.RemoveAll(stage)
		if err != nil {
			return err
		}
		if cleanupErr != nil {
			return cleanupErr
		}
	}
	manifest, err := release.NewRuntimeManifest(1, version, artifacts, supported)
	if err != nil {
		return err
	}
	data, err := release.Serialize(manifest)
	if err != nil {
		return err
	}
	return release.WriteSigned(filepath.Join(dist, ManifestPrefix+version+".json"), data, privateKey, publicKey)
}

func buildTarget(ctx context.Context, root, dist, stage, version string, t target, fetch nativeFetcher, artifacts *[]release.Artifact) error {
	if info, err := os.Stat(filepath.Join(root, "flutter_app", "build", "web", "index.html")); err != nil {
		return fmt.Errorf("web client is missing: %w", err)
	} else if !info.Mode().IsRegular() {
		return fmt.Errorf("web client index is not a regular file")
	}
	app := filepath.Join(stage, "app")
	bin := "neorecall"
	if t.platform == "windows" {
		bin += ".exe"
	}
	if err := os.MkdirAll(filepath.Join(app, "bin"), 0o755); err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(dist, t.binary))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(app, "bin", bin), data, 0o755); err != nil {
		return err
	}
	if err := fetch(ctx, t.platform, t.arch, filepath.Join(app, "bin")); err != nil {
		return fmt.Errorf("native files for %s-%s: %w", t.platform, t.arch, err)
	}
	for _, p := range [][2]string{{"flutter_app/build/web", "flutter_app/build/web"}, {"landing", "landing"}, {"test/fixtures", "test/fixtures"}} {
		if err := os.CopyFS(filepath.Join(app, filepath.FromSlash(p[1])), os.DirFS(filepath.Join(root, filepath.FromSlash(p[0])))); err != nil {
			return err
		}
	}
	name := fmt.Sprintf("neorecall-runtime-%s-%s-%s.zip", t.platform, t.arch, version)
	archive := filepath.Join(dist, name)
	if err := release.CreateZip(stage, archive); err != nil {
		return err
	}
	sum, size, err := release.FileDigest(archive)
	if err != nil {
		return err
	}
	*artifacts = append(*artifacts, release.Artifact{Platform: t.platform, Architecture: t.arch, AssetName: name, SHA256: sum, SizeBytes: size})
	return nil
}
