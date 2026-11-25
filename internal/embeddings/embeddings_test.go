package embeddings_test

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

func TestTokenizerLSHBandsAndSearchVector(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	_ = cfg.Paths.Ensure()

	// Write a tiny HuggingFace tokenizer.json fixture and test Encode.
	tokPath := filepath.Join(home, "tokenizer.json")
	tokJSON, _ := json.Marshal(map[string]any{
		"model": map[string]any{
			"type":   "Unigram",
			"unk_id": 3,
			"vocab": [][]any{
				{"<s>", 0.0},
				{"<pad>", 0.0},
				{"</s>", 0.0},
				{"<unk>", 0.0},
				{"▁query", -1.0},
				{":", -1.2},
				{"▁coffee", -1.5},
				{"▁meeting", -1.4},
			},
		},
	})
	if err := os.WriteFile(tokPath, tokJSON, 0o600); err != nil {
		t.Fatal(err)
	}
	tok, err := embeddings.LoadTokenizer(tokPath)
	if err != nil {
		t.Fatal(err)
	}
	ids, mask := tok.Encode("query: coffee meeting")
	if len(ids) < 4 || len(ids) != len(mask) || ids[0] != 0 || ids[len(ids)-1] != 2 {
		t.Fatalf("unexpected encoded tokens ids=%v mask=%v", ids, mask)
	}

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	uid := "00000000-0000-0000-0000-000000000001"
	_, err = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'alice', 'a@b.c', 'hash', 'admin')`, uid)
	if err != nil {
		t.Fatal(err)
	}

	unitVec := func(axis int) []float32 {
		v := make([]float32, 384)
		for i := range v {
			v[i] = 0.01
		}
		v[axis] = 10.0
		var s float64
		for _, x := range v {
			s += float64(x) * float64(x)
		}
		n := float32(math.Sqrt(s))
		for i := range v {
			v[i] /= n
		}
		return v
	}

	svc := &embeddings.Service{
		DB:   db,
		Cfg:  func() config.Config { return cfg },
		Jobs: &jobs.Service{DB: db},
		TestEmbedFn: func(_ context.Context, text, _ string) ([]float32, error) {
			if strings.Contains(strings.ToLower(text), "coffee") {
				return unitVec(7), nil
			}
			return unitVec(42), nil
		},
	}

	tx, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	t1, t2 := "Coffee", "Deploy"
	d1, err := embeddings.UpsertDocumentExec(ctx, tx, 3, uid, "memory", "m1", &t1, "coffee chat", "2026-01-01T10:00:00Z", 7)
	if err != nil {
		t.Fatal(err)
	}
	d2, err := embeddings.UpsertDocumentExec(ctx, tx, 3, uid, "memory", "m2", &t2, "release notes", "2026-01-01T11:00:00Z", 5)
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := svc.EmbedDocuments(ctx, []int64{d1.ID, d2.ID}); err != nil {
		t.Fatal(err)
	}

	matches, err := svc.SearchVector(ctx, uid, []string{"memory"}, unitVec(7), 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 2 || matches[0].DocumentID != d1.ID || matches[0].Similarity < 0.99 {
		t.Fatalf("expected d1 first with high similarity, got %+v", matches)
	}

	// The closest legacy row must remain searchable even when enough indexed rows exist.
	if _, err := db.W.ExecContext(ctx, `DELETE FROM search_embedding_bands WHERE document_id=?`, d1.ID); err != nil {
		t.Fatal(err)
	}
	legacy, err := svc.SearchVector(ctx, uid, nil, unitVec(7), 1)
	if err != nil || len(legacy) != 1 || legacy[0].DocumentID != d1.ID {
		t.Fatalf("legacy embedding not ranked: %+v %v", legacy, err)
	}
	tx2, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := embeddings.RemoveBySourcesTx(ctx, tx2, uid, []embeddings.SearchSourceRef{{Kind: "memory", SourceID: "m1"}}); err != nil {
		t.Fatal(err)
	}
	_ = tx2.Commit()
	matchesAfter, err := svc.SearchVector(ctx, uid, nil, unitVec(7), 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(matchesAfter) != 1 || matchesAfter[0].DocumentID != d2.ID {
		t.Fatalf("expected only d2 after m1 removal, got %+v", matchesAfter)
	}
	// Legacy archives may contain more than 1,000 embeddings without bands.
	_, err = db.W.ExecContext(ctx, `WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1001) INSERT INTO search_documents(user_id,kind,source_id,body,occurred_at,text_hash) SELECT ?, 'memory', 'legacy-' || x, 'legacy', '2026-01-01', 'hash' FROM n`, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO search_embeddings(document_id,user_id,model_revision,dimensions,embedding,text_hash) SELECT id,user_id,'legacy',384,?,text_hash FROM search_documents WHERE user_id=? AND source_id LIKE 'legacy-%'`, transcription.VectorToBytes(unitVec(42)), uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `UPDATE search_embeddings SET embedding=? WHERE document_id=(SELECT id FROM search_documents WHERE user_id=? AND source_id='legacy-1001')`, transcription.VectorToBytes(unitVec(99)), uid)
	if err != nil {
		t.Fatal(err)
	}
	var lastID int64
	if err = db.R.QueryRowContext(ctx, `SELECT id FROM search_documents WHERE user_id=? AND source_id='legacy-1001'`, uid).Scan(&lastID); err != nil {
		t.Fatal(err)
	}
	large, err := svc.SearchVector(ctx, uid, nil, unitVec(99), 1)
	if err != nil || len(large) != 1 || large[0].DocumentID != lastID {
		t.Fatalf("large legacy archive: %+v %v", large, err)
	}

}
