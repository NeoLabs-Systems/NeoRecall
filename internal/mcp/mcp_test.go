package mcp_test

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
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/mcp"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

func TestMCPOAuthChallengeAndToolsCall(t *testing.T) {
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

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	uid := "00000000-0000-0000-0000-000000000081"
	_, _ = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'mcpu', 'mcp@x.io', 'h', 'user')`, uid)

	cfgFn := func() config.Config { return cfg }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	authSvc := &auth.Service{DB: db, Cfg: cfgFn}
	authn := &auth.Authenticator{Service: authSvc, Log: log}
	emb := &embeddings.Service{DB: db, Cfg: cfgFn}
	srch := &search.Service{DB: db, Cfg: cfgFn, Embeddings: emb, Log: log}
	ask := &search.AskService{Search: srch, Usage: &usage.Service{DB: db}}
	mems := &memories.Service{DB: db, Cfg: cfgFn, Jobs: &jobs.Service{DB: db}, Log: log}

	mux := http.NewServeMux()
	(&mcp.Server{Auth: authn, Search: srch, Ask: ask, Memories: mems, Log: log, Version: "1.2.3"}).Mount(mux)

	// Unauthenticated -> 401 with WWW-Authenticate Bearer resource_metadata.
	unauthReq := httptest.NewRequest(http.MethodPost, "/mcp", bytes.NewBufferString(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`))
	unauthReq.Host = "recall.local"
	unauthRec := httptest.NewRecorder()
	mux.ServeHTTP(unauthRec, unauthReq)
	if unauthRec.Code != http.StatusUnauthorized || !strings.Contains(unauthRec.Header().Get("WWW-Authenticate"), "oauth-protected-resource") {
		t.Fatalf("expected 401 with resource_metadata header, got %d %q", unauthRec.Code, unauthRec.Header().Get("WWW-Authenticate"))
	}

	key, _ := authSvc.CreateAPIKey(ctx, uid, "mcp", []string{"memories:read", "search:read"}, nil)

	callRPC := func(payload string) map[string]any {
		req := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(payload))
		req.Header.Set("Authorization", "Bearer "+key.Token)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("rpc status=%d body=%s", rec.Code, rec.Body.String())
		}
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out
	}

	listRes := callRPC(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	tools := listRes["result"].(map[string]any)["tools"].([]any)
	if len(tools) != 6 {
		t.Fatalf("expected 6 MCP tools, got %d", len(tools))
	}

	callRes := callRPC(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_recent_memories","arguments":{"limit":5}}}`)
	content := callRes["result"].(map[string]any)["content"].([]any)
	text := content[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, `"items":[]`) {
		t.Fatalf("unexpected tool output: %s", text)
	}
}
