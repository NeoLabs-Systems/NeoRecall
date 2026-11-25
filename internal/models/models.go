// Package models downloads, extracts, verifies, and prunes pinned speech,
// diarization, and semantic embedding model assets from manifest.json.
package models

import (
	"archive/tar"
	"compress/bzip2"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

//go:embed manifest.json
var embeddedManifest []byte

type Manifest struct {
	SchemaVersion int          `json:"schemaVersion"`
	Retired       []string     `json:"retired"`
	Models        []ModelEntry `json:"models"`
}

type ArchiveSpec struct {
	Filename        string `json:"filename"`
	URL             string `json:"url"`
	Size            int64  `json:"size"`
	SHA256          string `json:"sha256"`
	StripComponents int    `json:"stripComponents"`
}

type HuggingFaceSpec struct {
	Repo string `json:"repo"`
}

type FileSpec struct {
	Path        string `json:"path"`
	URL         string `json:"url,omitempty"`
	HubPath     string `json:"hubPath,omitempty"`
	ArchivePath string `json:"archivePath,omitempty"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
}

type ModelEntry struct {
	ID          string           `json:"id"`
	Revision    string           `json:"revision"`
	License     string           `json:"license"`
	LicenseURL  string           `json:"licenseUrl"`
	Archive     *ArchiveSpec     `json:"archive,omitempty"`
	HuggingFace *HuggingFaceSpec `json:"huggingFace,omitempty"`
	Files       []FileSpec       `json:"files"`
}

type Progress struct {
	File     string
	Received int64
	Total    int64
}

type DownloadResult struct {
	Path   string
	Cached bool
}

type VerificationFailure struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

type PrunedEntry struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

func LoadManifest(appDir string) (Manifest, error) {
	raw := embeddedManifest
	if appDir != "" {
		if disk, err := os.ReadFile(filepath.Join(appDir, "models", "manifest.json")); err == nil {
			raw = disk
		}
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return Manifest{}, err
	}
	return m, nil
}

func FileSHA256(filename string) (string, error) {
	f, err := os.Open(filename)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func validFile(filename string, spec FileSpec) (bool, error) {
	st, err := os.Stat(filename)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if st.Size() != spec.Size {
		return false, nil
	}
	sum, err := FileSHA256(filename)
	if err != nil {
		return false, err
	}
	return sum == spec.SHA256, nil
}

func DownloadFile(ctx context.Context, client *http.Client, modelsDir string, spec FileSpec, onProgress func(Progress)) (DownloadResult, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Minute}
	}
	dst := filepath.Join(modelsDir, filepath.FromSlash(spec.Path))
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return DownloadResult{}, err
	}
	if ok, _ := validFile(dst, spec); ok {
		return DownloadResult{Path: dst, Cached: true}, nil
	}

	partial := dst + ".partial"
	var offset int64
	if st, err := os.Stat(partial); err == nil {
		if st.Size() > spec.Size {
			_ = os.Remove(partial)
		} else {
			offset = st.Size()
		}
	}

	attempt := func(startOffset int64) (int, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, spec.URL, nil)
		if err != nil {
			return 0, err
		}
		if startOffset > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", startOffset))
		}
		resp, err := client.Do(req)
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 || (startOffset > 0 && resp.StatusCode != http.StatusPartialContent) {
			return resp.StatusCode, fmt.Errorf("model download failed with HTTP %d: %s", resp.StatusCode, spec.URL)
		}
		flags := os.O_CREATE | os.O_WRONLY
		if startOffset > 0 {
			flags |= os.O_APPEND
		} else {
			flags |= os.O_TRUNC
		}
		f, err := os.OpenFile(partial, flags, 0o600)
		if err != nil {
			return resp.StatusCode, err
		}
		received := startOffset
		buf := make([]byte, 64*1024)
		for {
			n, rerr := resp.Body.Read(buf)
			if n > 0 {
				if _, werr := f.Write(buf[:n]); werr != nil {
					_ = f.Close()
					return resp.StatusCode, werr
				}
				received += int64(n)
				if onProgress != nil {
					onProgress(Progress{File: spec.Path, Received: received, Total: spec.Size})
				}
			}
			if errors.Is(rerr, io.EOF) {
				break
			}
			if rerr != nil {
				_ = f.Close()
				return resp.StatusCode, rerr
			}
		}
		if err := f.Close(); err != nil {
			return resp.StatusCode, err
		}
		return resp.StatusCode, nil
	}

	_, err := attempt(offset)
	if err != nil && offset > 0 {
		_ = os.Remove(partial)
		_, err = attempt(0)
	}
	if err != nil {
		return DownloadResult{}, err
	}

	st, err := os.Stat(partial)
	if err != nil {
		return DownloadResult{}, err
	}
	if st.Size() != spec.Size {
		return DownloadResult{}, fmt.Errorf("downloaded size for %s is %d, expected %d", spec.Path, st.Size(), spec.Size)
	}
	sum, err := FileSHA256(partial)
	if err != nil {
		return DownloadResult{}, err
	}
	if sum != spec.SHA256 {
		_ = os.Remove(partial)
		return DownloadResult{}, fmt.Errorf("SHA-256 verification failed for %s", spec.Path)
	}
	if err := os.Rename(partial, dst); err != nil {
		return DownloadResult{}, err
	}
	return DownloadResult{Path: dst, Cached: false}, nil
}

func InstallModel(ctx context.Context, client *http.Client, modelsDir string, m ModelEntry, onProgress func(Progress)) ([]DownloadResult, error) {
	allCached := true
	results := make([]DownloadResult, 0, len(m.Files))
	for _, f := range m.Files {
		dst := filepath.Join(modelsDir, filepath.FromSlash(f.Path))
		ok, err := validFile(dst, f)
		if err != nil || !ok {
			allCached = false
			break
		}
		results = append(results, DownloadResult{Path: dst, Cached: true})
	}
	if allCached && len(results) == len(m.Files) {
		return results, nil
	}
	results = results[:0]

	if m.HuggingFace != nil {
		rev := m.Revision
		if rev == "" {
			rev = "main"
		}
		for _, f := range m.Files {
			hubPath := f.HubPath
			if hubPath == "" {
				hubPath = f.Path
			}
			dlSpec := f
			if dlSpec.URL == "" {
				dlSpec.URL = fmt.Sprintf("https://huggingface.co/%s/resolve/%s/%s", m.HuggingFace.Repo, rev, strings.TrimPrefix(hubPath, "/"))
			}
			res, err := DownloadFile(ctx, client, modelsDir, dlSpec, onProgress)
			if err != nil {
				return nil, fmt.Errorf("install %s via Hugging Face: %w", m.ID, err)
			}
			results = append(results, res)
		}
		return results, nil
	}

	if m.Archive != nil {
		archSpec := FileSpec{
			Path:   filepath.ToSlash(filepath.Join(".downloads", m.Archive.Filename)),
			URL:    m.Archive.URL,
			Size:   m.Archive.Size,
			SHA256: m.Archive.SHA256,
		}
		dl, err := DownloadFile(ctx, client, modelsDir, archSpec, onProgress)
		if err != nil {
			return nil, err
		}
		defer os.Remove(dl.Path)

		extractRoot := filepath.Join(modelsDir, fmt.Sprintf(".extract-%s-%d", m.ID, os.Getpid()))
		_ = os.RemoveAll(extractRoot)
		if err := os.MkdirAll(extractRoot, 0o700); err != nil {
			return nil, err
		}
		defer os.RemoveAll(extractRoot)

		if err := extractTarBZ2(dl.Path, extractRoot, m.Archive.StripComponents); err != nil {
			return nil, fmt.Errorf("extract %s: %w", m.Archive.Filename, err)
		}

		for _, f := range m.Files {
			rel := f.ArchivePath
			if rel == "" {
				rel = path.Base(f.Path)
			}
			src := filepath.Join(extractRoot, filepath.FromSlash(rel))
			ok, err := validFile(src, f)
			if err != nil || !ok {
				return nil, fmt.Errorf("extracted model file failed verification: %s", rel)
			}
		}
		for _, f := range m.Files {
			rel := f.ArchivePath
			if rel == "" {
				rel = path.Base(f.Path)
			}
			src := filepath.Join(extractRoot, filepath.FromSlash(rel))
			dst := filepath.Join(modelsDir, filepath.FromSlash(f.Path))
			if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
				return nil, err
			}
			tmp := dst + ".installing"
			_ = os.Remove(tmp)
			if err := copyFilePrivate(src, tmp); err != nil {
				return nil, err
			}
			_ = os.Remove(dst)
			if err := os.Rename(tmp, dst); err != nil {
				return nil, err
			}
			results = append(results, DownloadResult{Path: dst, Cached: false})
		}
		return results, nil
	}

	for _, f := range m.Files {
		res, err := DownloadFile(ctx, client, modelsDir, f, onProgress)
		if err != nil {
			return nil, err
		}
		results = append(results, res)
	}
	return results, nil
}

func DownloadAll(ctx context.Context, client *http.Client, appDir, modelsDir string, onProgress func(Progress)) ([]DownloadResult, error) {
	m, err := LoadManifest(appDir)
	if err != nil {
		return nil, err
	}
	var all []DownloadResult
	for _, entry := range m.Models {
		res, err := InstallModel(ctx, client, modelsDir, entry, onProgress)
		if err != nil {
			return nil, err
		}
		all = append(all, res...)
	}
	return all, nil
}

func VerifyAll(appDir, modelsDir string) ([]VerificationFailure, error) {
	m, err := LoadManifest(appDir)
	if err != nil {
		return nil, err
	}
	var failures []VerificationFailure
	for _, entry := range m.Models {
		for _, f := range entry.Files {
			p := filepath.Join(modelsDir, filepath.FromSlash(f.Path))
			st, err := os.Stat(p)
			if err != nil {
				failures = append(failures, VerificationFailure{Path: f.Path, Reason: "missing"})
				continue
			}
			if st.Size() != f.Size {
				failures = append(failures, VerificationFailure{Path: f.Path, Reason: "size"})
				continue
			}
			sum, err := FileSHA256(p)
			if err != nil || sum != f.SHA256 {
				failures = append(failures, VerificationFailure{Path: f.Path, Reason: "sha256"})
			}
		}
	}
	return failures, nil
}

func PruneRetired(appDir, modelsDir string) ([]PrunedEntry, error) {
	m, err := LoadManifest(appDir)
	if err != nil {
		return nil, err
	}
	absRoot, err := filepath.Abs(modelsDir)
	if err != nil {
		return nil, err
	}
	var removed []PrunedEntry
	for _, rel := range m.Retired {
		var total int64
		for _, cand := range []string{rel, rel + ".partial"} {
			target := filepath.Join(absRoot, filepath.FromSlash(cand))
			relBack, rerr := filepath.Rel(absRoot, target)
			if rerr != nil || relBack == "." || strings.HasPrefix(relBack, "..") || filepath.IsAbs(relBack) {
				continue
			}
			if _, serr := os.Lstat(target); serr != nil {
				continue
			}
			total += pathSize(target)
			_ = os.RemoveAll(target)
		}
		if total > 0 {
			removed = append(removed, PrunedEntry{Path: rel, Bytes: total})
		}
	}
	return removed, nil
}

func pathSize(p string) int64 {
	var total int64
	_ = filepath.WalkDir(p, func(_ string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if info, ierr := d.Info(); ierr == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

func extractTarBZ2(archivePath, dstDir string, stripComponents int) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()
	tr := tar.NewReader(bzip2.NewReader(f))
	absDst, err := filepath.Abs(dstDir)
	if err != nil {
		return err
	}
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		clean := path.Clean(strings.TrimPrefix(hdr.Name, "./"))
		parts := strings.Split(clean, "/")
		if stripComponents >= len(parts) {
			continue
		}
		rel := path.Join(parts[stripComponents:]...)
		if rel == "" || rel == "." || strings.HasPrefix(rel, "..") {
			continue
		}
		outPath := filepath.Join(absDst, filepath.FromSlash(rel))
		if !strings.HasPrefix(outPath, absDst+string(filepath.Separator)) && outPath != absDst {
			return fmt.Errorf("unsafe archive path %q", hdr.Name)
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(outPath, 0o700); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(outPath), 0o700); err != nil {
				return err
			}
			of, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				return err
			}
			if _, err := io.Copy(of, tr); err != nil {
				_ = of.Close()
				return err
			}
			if err := of.Close(); err != nil {
				return err
			}
		}
	}
}

func copyFilePrivate(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}
