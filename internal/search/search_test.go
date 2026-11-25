package search_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

type stubAskAI struct {
	plan search.QueryPlan
}

func (s *stubAskAI) PlanQuery(_ context.Context, _, _, _, _ string) (search.QueryPlan, error) {
	return s.plan, nil
}

func (s *stubAskAI) Answer(_ context.Context, _, _ string, items []map[string]any, beforeAttempt func() error, _ map[string]any) (string, []string, error) {
	if beforeAttempt != nil {
		if err := beforeAttempt(); err != nil {
			return "", nil, err
		}
	}
	if len(items) == 0 {
		return "Nothing recorded.", nil, nil
	}
	src, _ := items[0]["sourceId"].(string)
	return "Discussed Q3 launch plans.", []string{src}, nil
}

func TestHybridSearchAndAskRoutes(t *testing.T) {
	ctx := context.Background()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "NEORECALL_ASK_MAX_PER_HOUR":
			return "2"
		default:
			return ""
		}
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	_ = cfg.Paths.Ensure()

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}

	uid := "00000000-0000-0000-0000-000000000010"
	_, err = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'user', 'u@x.io', 'hash', 'user')`, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO user_settings (user_id, key, value_json) VALUES (?, 'timezone', '"UTC"')`, uid)
	if err != nil {
		t.Fatal(err)
	}

	emb := &embeddings.Service{
		DB:  db,
		Cfg: func() config.Config { return cfg },
		TestEmbedFn: func(_ context.Context, text, _ string) ([]float32, error) {
			v := make([]float32, 384)
			if strings.Contains(strings.ToLower(text), "launch") {
				v[0] = 1
			} else {
				v[1] = 1
			}
			return v, nil
		},
	}

	tx, err := db.W.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	t1 := "Q3 Launch Prep"
	doc1, err := embeddings.UpsertDocumentExec(ctx, tx, 3, uid, "memory", "mem-1", &t1, "Finalized launch timeline with design", "2026-03-10T14:00:00.000Z", 8)
	if err != nil {
		t.Fatal(err)
	}
	doc2, err := embeddings.UpsertDocumentExec(ctx, tx, 3, uid, "segment", "seg-1", nil, "launch date sounds good", "2026-03-10T13:55:00.000Z", 3)
	if err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit()
	if err := emb.EmbedDocuments(ctx, []int64{doc1.ID, doc2.ID}); err != nil {
		t.Fatal(err)
	}

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	srvc := &search.Service{
		DB:         db,
		Cfg:        func() config.Config { return cfg },
		Embeddings: emb,
		Log:        log,
	}
	res, err := srvc.Search(ctx, uid, "launch timeline", search.SearchOptions{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Results) != 2 || res.Results[0].Kind != "memory" {
		t.Fatalf("expected memory ranked first, got results=%+v", res.Results)
	}

	askSvc := &search.AskService{
		Search: srvc,
		Usage:  &usage.Service{DB: db},
		AI:     &stubAskAI{plan: search.QueryPlan{SearchQueries: []string{"launch timeline"}}},
	}

	authSvc := &auth.Service{DB: db, Cfg: func() config.Config { return cfg }}
	key, err := authSvc.CreateAPIKey(ctx, uid, "test", []string{"search:read", "search:ask"}, nil)
	if err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	(&search.Routes{
		Search: srvc,
		Ask:    askSvc,
		Auth:   &auth.Authenticator{Service: authSvc, Log: log},
		Log:    log,
	}).Mount(mux)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/search?q=launch", nil)
	req.Header.Set("Authorization", "Bearer "+key.Token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /search status=%d body=%s", rec.Code, rec.Body.String())
	}

	// Ask twice succeeds; third hit hits ASK_RATE_LIMITED (limit=2).
	for i := 0; i < 2; i++ {
		askReq := httptest.NewRequest(http.MethodPost, "/api/v1/search/ask", bytes.NewBufferString(`{"question":"What did we decide about the launch?"}`))
		askReq.Header.Set("Authorization", "Bearer "+key.Token)
		askRec := httptest.NewRecorder()
		mux.ServeHTTP(askRec, askReq)
		if askRec.Code != http.StatusOK {
			t.Fatalf("ask #%d failed status=%d body=%s", i+1, askRec.Code, askRec.Body.String())
		}
		var body search.AskResponse
		_ = json.Unmarshal(askRec.Body.Bytes(), &body)
		if len(body.Citations) != 1 || body.Citations[0].Link != "/memories/mem-1" {
			t.Fatalf("expected /memories/mem-1 citation link, got %+v", body.Citations)
		}
	}

	askReq3 := httptest.NewRequest(http.MethodPost, "/api/v1/search/ask", bytes.NewBufferString(`{"question":"Another launch question?"}`))
	askReq3.Header.Set("Authorization", "Bearer "+key.Token)
	askRec3 := httptest.NewRecorder()
	mux.ServeHTTP(askRec3, askReq3)
	if askRec3.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on 3rd ask, got status=%d body=%s", askRec3.Code, askRec3.Body.String())
	}
}
