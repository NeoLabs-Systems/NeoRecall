package runtimebundle

import (
	"archive/tar"
	"compress/bzip2"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"time"
)

type pin struct{ url, sha256 string }

type native struct {
	libraries     pin
	libraryNames  []string
	ffmpeg        pin
	ffmpegLicense pin
	ffmpegReadme  pin
}

const thirdPartyNotice = "THIRD-PARTY.txt"

func nativeFor(platform, arch string) (native, error) {
	n, ok := natives[platform+"-"+arch]
	if !ok {
		return native{}, fmt.Errorf("no native libraries are pinned for %s-%s", platform, arch)
	}
	return n, nil
}

// FetchLibraries downloads the verified sherpa-onnx and ONNX Runtime libraries
// of a platform ("linux", "macos", "windows") and architecture ("x64",
// "arm64") into dir.
func FetchLibraries(ctx context.Context, platform, arch, dir string) error {
	n, err := nativeFor(platform, arch)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return withDownload(ctx, n.libraries, func(r io.Reader) error {
		return extractLibraries(tar.NewReader(bzip2.NewReader(r)), n.libraryNames, dir)
	})
}

// fetchNative fills a runtime bundle's bin directory: the libraries, ffmpeg
// beside the server binary, and the license texts that must travel with them.
func fetchNative(ctx context.Context, platform, arch, dir string) error {
	n, err := nativeFor(platform, arch)
	if err != nil {
		return err
	}
	if err := FetchLibraries(ctx, platform, arch, dir); err != nil {
		return err
	}
	ffmpeg := "ffmpeg"
	if platform == "windows" {
		ffmpeg += ".exe"
	}
	if err := withDownload(ctx, n.ffmpeg, func(r io.Reader) error {
		unzipped, err := gzip.NewReader(r)
		if err != nil {
			return err
		}
		return writeFile(filepath.Join(dir, ffmpeg), unzipped, 0o755)
	}); err != nil {
		return err
	}
	for name, p := range map[string]pin{"ffmpeg.LICENSE": n.ffmpegLicense, "ffmpeg.README": n.ffmpegReadme} {
		if err := withDownload(ctx, p, func(r io.Reader) error {
			return writeFile(filepath.Join(dir, name), r, 0o644)
		}); err != nil {
			return err
		}
	}
	notice := "sherpa-onnx " + sherpaVersion + " (Apache-2.0): https://github.com/k2-fsa/sherpa-onnx\n" +
		"ONNX Runtime (MIT): https://github.com/microsoft/onnxruntime\n" +
		"ffmpeg " + ffmpegRelease + " (see ffmpeg.LICENSE and ffmpeg.README): https://github.com/eugeneware/ffmpeg-static\n"
	return os.WriteFile(filepath.Join(dir, thirdPartyNotice), []byte(notice), 0o644)
}

// withDownload saves a pinned file, checks its digest and only then hands it to
// use, so nothing unverified is ever unpacked.
func withDownload(ctx context.Context, p pin, use func(io.Reader) error) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", p.url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: HTTP %d", p.url, resp.StatusCode)
	}
	tmp, err := os.CreateTemp("", "neorecall-native-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	digest := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, digest), resp.Body); err != nil {
		return fmt.Errorf("download %s: %w", p.url, err)
	}
	if got := hex.EncodeToString(digest.Sum(nil)); got != p.sha256 {
		return fmt.Errorf("download %s: SHA-256 is %s, expected %s", p.url, got, p.sha256)
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return use(tmp)
}

// extractLibraries writes the named files from an archive's lib directory.
func extractLibraries(r *tar.Reader, names []string, dir string) error {
	missing := slices.Clone(names)
	for len(missing) > 0 {
		header, err := r.Next()
		if errors.Is(err, io.EOF) {
			return fmt.Errorf("archive is missing %v", missing)
		}
		if err != nil {
			return err
		}
		name := path.Base(header.Name)
		i := slices.Index(missing, name)
		if i < 0 || header.Typeflag != tar.TypeReg || path.Base(path.Dir(header.Name)) != "lib" {
			continue
		}
		if err := writeFile(filepath.Join(dir, name), r, 0o755); err != nil {
			return err
		}
		missing = slices.Delete(missing, i, i+1)
	}
	return nil
}

func writeFile(name string, r io.Reader, mode os.FileMode) error {
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, r)
	return errors.Join(err, f.Close())
}
