package embeddings

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/neorouter"
)

const (
	LocalEmbeddingModelID = "Xenova/multilingual-e5-small"
)

type EmbedResult struct {
	Vector []float32
	Space  string
}

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	NeoRouter *neorouter.Service
	Jobs      *jobs.Service
	Log       *slog.Logger

	// Optional test override hook (bypasses ORT/NeoRouter cleanly in unit tests).
	TestEmbedFn func(ctx context.Context, text, prefix string) ([]float32, error)

	mu        sync.Mutex
	tokenizer *Tokenizer
	embedder  *ortEmbedder
	modelDir  string
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) modelPaths() (tokenizerPath, onnxPath string) {
	base := filepath.Join(s.cfg().Paths.Models, "Xenova", "multilingual-e5-small")
	return filepath.Join(base, "tokenizer.json"), filepath.Join(base, "onnx", "model_quantized.onnx")
}

func (s *Service) LocalModelRevision() string {
	c := s.cfg()
	m := c.EmbeddingModel
	if m == "" {
		m = LocalEmbeddingModelID
	}
	d := c.EmbeddingDimensions
	if d <= 0 {
		d = 384
	}
	return fmt.Sprintf("%s@%d", m, d)
}

func (s *Service) VectorReady() bool {
	if s.TestEmbedFn != nil {
		return true
	}
	if s.NeoRouter != nil {
		if conn, err := s.NeoRouter.Get(context.Background()); err == nil && conn != nil && conn.Embeddings {
			return true
		}
	}
	tokPath, onnxPath := s.modelPaths()
	if _, err := os.Stat(tokPath); err != nil {
		return false
	}
	if _, err := os.Stat(onnxPath); err != nil {
		return false
	}
	return HasONNXRuntime(s.cfg())
}

func (s *Service) ensureLocalLoaded() (*Tokenizer, *ortEmbedder, error) {
	tokPath, onnxPath := s.modelPaths()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tokenizer != nil && s.embedder != nil && s.modelDir == tokPath {
		return s.tokenizer, s.embedder, nil
	}
	if _, err := os.Stat(tokPath); err != nil {
		return nil, nil, fmt.Errorf("embedding tokenizer not installed (%s): run neorecall setup", tokPath)
	}
	if _, err := os.Stat(onnxPath); err != nil {
		return nil, nil, fmt.Errorf("embedding model not installed (%s): run neorecall setup", onnxPath)
	}
	tok, err := LoadTokenizer(tokPath)
	if err != nil {
		return nil, nil, fmt.Errorf("load embedding tokenizer: %w", err)
	}
	emb, err := newORTEmbedder(s.cfg(), onnxPath)
	if err != nil {
		return nil, nil, err
	}
	if s.embedder != nil {
		s.embedder.Close()
	}
	s.tokenizer = tok
	s.embedder = emb
	s.modelDir = tokPath
	return s.tokenizer, s.embedder, nil
}

func (s *Service) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.embedder != nil {
		s.embedder.Close()
		s.embedder = nil
	}
}

func formatE5Input(text, prefix string) string {
	trimmed := strings.TrimSpace(text)
	switch prefix {
	case "query", "passage":
		return prefix + ": " + trimmed
	default:
		if prefix != "" {
			return prefix + ": " + trimmed
		}
		return "passage: " + trimmed
	}
}

func (s *Service) EmbedLocal(ctx context.Context, text, prefix string) ([]float32, error) {
	if s.TestEmbedFn != nil {
		return s.TestEmbedFn(ctx, text, prefix)
	}
	tok, emb, err := s.ensureLocalLoaded()
	if err != nil {
		return nil, err
	}
	ids, mask := tok.Encode(formatE5Input(text, prefix))
	return emb.InferMeanPooled(ids, mask)
}

func (s *Service) spaceInUse(ctx context.Context, model string) bool {
	if s.DB == nil {
		return false
	}
	var cnt int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM search_embeddings WHERE model_revision LIKE ?`, "neorouter:"+model+"%").Scan(&cnt)
	return cnt > 0
}

func (s *Service) EmbedDetailed(ctx context.Context, text, prefix string) (EmbedResult, error) {
	if s.TestEmbedFn != nil {
		v, err := s.TestEmbedFn(ctx, text, prefix)
		return EmbedResult{Vector: v}, err
	}
	if s.NeoRouter != nil {
		conn, err := s.NeoRouter.Get(ctx)
		if err == nil && conn != nil && conn.Embeddings {
			dims := s.cfg().EmbeddingDimensions
			if dims <= 0 {
				dims = 384
			}
			res, err := s.NeoRouter.Embed(ctx, conn, strings.TrimSpace(text), prefix, dims)
			if err != nil && s.NeoRouter.ResetUnusedPin(ctx, conn, err, func(model string) bool {
				return !s.spaceInUse(ctx, model)
			}) {
				res, err = s.NeoRouter.Embed(ctx, conn, strings.TrimSpace(text), prefix, dims)
			}
			if err != nil {
				return EmbedResult{}, err
			}
			return EmbedResult{Vector: res.Vector, Space: res.Space}, nil
		}
	}
	vec, err := s.EmbedLocal(ctx, text, prefix)
	if err != nil {
		return EmbedResult{}, err
	}
	return EmbedResult{Vector: vec}, nil
}

func (s *Service) Embed(ctx context.Context, text, prefix string) ([]float32, error) {
	res, err := s.EmbedDetailed(ctx, text, prefix)
	return res.Vector, err
}
