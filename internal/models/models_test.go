package models_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/models"
)

func TestDownloadFileResumeVerifyAndPruneRetired(t *testing.T) {
	ctx := context.Background()
	modelsDir := t.TempDir()

	payload := []byte("0123456789abcdef-silero-vad-onnx-payload")
	sum := sha256.Sum256(payload)
	sumHex := hex.EncodeToString(sum[:])

	var sawRange bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rng := r.Header.Get("Range"); strings.HasPrefix(rng, "bytes=") {
			sawRange = true
			startStr := strings.TrimSuffix(strings.TrimPrefix(rng, "bytes="), "-")
			start, _ := strconv.Atoi(startStr)
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(payload[start:])
			return
		}
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	spec := models.FileSpec{
		Path:   "vad/test_model.onnx",
		URL:    srv.URL + "/test_model.onnx",
		Size:   int64(len(payload)),
		SHA256: sumHex,
	}
	partial := filepath.Join(modelsDir, "vad", "test_model.onnx.partial")
	_ = os.MkdirAll(filepath.Dir(partial), 0o700)
	if err := os.WriteFile(partial, payload[:8], 0o600); err != nil {
		t.Fatal(err)
	}

	res, err := models.DownloadFile(ctx, srv.Client(), modelsDir, spec, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !sawRange {
		t.Fatalf("expected HTTP Range resume from .partial")
	}
	if res.Cached {
		t.Fatalf("expected fresh download, got Cached=true")
	}

	// Second call hits cache without network errors.
	res2, err := models.DownloadFile(ctx, srv.Client(), modelsDir, spec, nil)
	if err != nil || !res2.Cached {
		t.Fatalf("expected Cached=true on repeat download: %+v err=%v", res2, err)
	}

	// Verify manifest loading and retired model pruning.
	m, err := models.LoadManifest("")
	if err != nil || len(m.Models) < 4 {
		t.Fatalf("expected embedded manifest with >=4 models, got %d err=%v", len(m.Models), err)
	}
	retiredPath := filepath.Join(modelsDir, "asr", "encoder.int8.onnx")
	_ = os.MkdirAll(filepath.Dir(retiredPath), 0o700)
	_ = os.WriteFile(retiredPath, []byte("stale-weights"), 0o600)
	pruned, err := models.PruneRetired("", modelsDir)
	if err != nil || len(pruned) != 1 || pruned[0].Path != "asr/encoder.int8.onnx" {
		t.Fatalf("expected retired prune of asr/encoder.int8.onnx, got %+v err=%v", pruned, err)
	}
	if _, err := os.Stat(retiredPath); !os.IsNotExist(err) {
		t.Fatalf("retired file still present")
	}
}
