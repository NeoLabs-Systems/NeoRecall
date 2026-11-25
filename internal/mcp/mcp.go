package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
)

type Server struct {
	Auth     *auth.Authenticator
	Search   *search.Service
	Ask      *search.AskService
	Memories *memories.Service
	Log      *slog.Logger
	Version  string
}

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

var mcpTools = []toolDef{
	{
		Name:        "ask_archive",
		Description: "Ask a natural-language question answered strictly from the user's recorded archive.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"question"},
			"properties": map[string]any{"question": map[string]any{"type": "string", "minLength": 1}},
		},
	},
	{
		Name:        "search_archive",
		Description: "Search memories, mini-memories, transcripts, and daily summaries.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"query"},
			"properties": map[string]any{
				"query": map[string]any{"type": "string", "minLength": 1},
				"kinds": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"from":  map[string]any{"type": "string"},
				"to":    map[string]any{"type": "string"},
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 100},
			},
		},
	},
	{
		Name:        "list_recent_memories",
		Description: "List recent consolidated memories.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 100},
				"type":  map[string]any{"type": "string"},
			},
		},
	},
	{
		Name:        "get_memory",
		Description: "Fetch a full memory card with linked entities, action items, sources, and context.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"id"},
			"properties": map[string]any{"id": map[string]any{"type": "string", "minLength": 1}},
		},
	},
	{
		Name:        "list_open_actions",
		Description: "List open tasks and promises extracted from recordings.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 100},
			},
		},
	},
	{
		Name:        "get_daily_summary",
		Description: "Read the daily summary for a local YYYY-MM-DD date.",
		InputSchema: map[string]any{
			"type": "object", "required": []string{"date"},
			"properties": map[string]any{"date": map[string]any{"type": "string"}},
		},
	},
}

func (s *Server) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /mcp", s.handleMCP)
	mux.HandleFunc("GET /mcp", s.handleMCPInfo)
}

func (s *Server) requireBearer(w http.ResponseWriter, r *http.Request) *auth.AuthContext {
	tok := auth.BearerToken(r)
	if tok != "" && s.Auth != nil {
		if ac := s.Auth.Resolve(r.Context(), tok); ac != nil {
			return ac
		}
	}
	scheme := "https"
	if r.TLS == nil && (strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "http") || strings.HasPrefix(r.Host, "localhost") || strings.HasPrefix(r.Host, "127.0.0.1")) {
		scheme = "http"
	}
	if p := r.Header.Get("X-Forwarded-Proto"); p != "" {
		scheme = strings.Split(p, ",")[0]
	}
	metaURL := fmt.Sprintf("%s://%s/.well-known/oauth-protected-resource", scheme, r.Host)
	w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer resource_metadata="%s"`, metaURL))
	httpx.WriteJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
	return nil
}

func (s *Server) handleMCPInfo(w http.ResponseWriter, r *http.Request) {
	if s.requireBearer(w, r) == nil {
		return
	}
	ver := s.Version
	if ver == "" {
		ver = "1.0.0"
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"name": "NeoRecall", "version": ver, "protocolVersion": "2024-11-05"})
}

func (s *Server) handleMCP(w http.ResponseWriter, r *http.Request) {
	ac := s.requireBearer(w, r)
	if ac == nil {
		return
	}
	var req struct {
		JSONRPC string         `json:"jsonrpc"`
		ID      any            `json:"id"`
		Method  string         `json:"method"`
		Params  map[string]any `json:"params"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": "Parse error"}})
		return
	}
	writeResult := func(res any) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": res})
	}
	writeErr := func(code int, msg string) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": req.ID, "error": map[string]any{"code": code, "message": msg}})
	}

	switch req.Method {
	case "initialize":
		ver := s.Version
		if ver == "" {
			ver = "1.0.0"
		}
		writeResult(map[string]any{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "NeoRecall", "version": ver},
		})
	case "notifications/initialized":
		w.WriteHeader(http.StatusAccepted)
	case "ping":
		writeResult(map[string]any{})
	case "tools/list":
		writeResult(map[string]any{"tools": mcpTools})
	case "tools/call":
		name, _ := req.Params["name"].(string)
		args, _ := req.Params["arguments"].(map[string]any)
		out, err := s.callTool(r.Context(), ac, name, args)
		if err != nil {
			writeResult(map[string]any{
				"isError": true,
				"content": []map[string]any{{"type": "text", "text": err.Error()}},
			})
			return
		}
		jb, _ := json.Marshal(out)
		writeResult(map[string]any{
			"content": []map[string]any{{"type": "text", "text": string(jb)}},
		})
	default:
		writeErr(-32601, "Method not found: "+req.Method)
	}
}

func (s *Server) callTool(ctx context.Context, ac *auth.AuthContext, name string, args map[string]any) (any, error) {
	str := func(k string) string { v, _ := args[k].(string); return strings.TrimSpace(v) }
	lim := func(def int) int {
		if f, ok := args["limit"].(float64); ok && f > 0 {
			return min(100, int(f))
		}
		return def
	}

	switch name {
	case "ask_archive":
		if !ac.HasScope("search:ask") {
			return nil, fmt.Errorf("missing scope search:ask")
		}
		q := str("question")
		if q == "" {
			return nil, fmt.Errorf("question is required")
		}
		return s.Ask.Ask(ctx, ac.UserID, q)
	case "search_archive":
		if !ac.HasScope("search:read") {
			return nil, fmt.Errorf("missing scope search:read")
		}
		q := str("query")
		if q == "" {
			return nil, fmt.Errorf("query is required")
		}
		var kinds []string
		if rawK, ok := args["kinds"].([]any); ok {
			for _, it := range rawK {
				if ks, ok := it.(string); ok && ks != "" {
					kinds = append(kinds, ks)
				}
			}
		}
		return s.Search.Search(ctx, ac.UserID, q, search.SearchOptions{
			Limit: lim(20), Kinds: kinds, From: str("from"), To: str("to"),
		})
	case "list_recent_memories":
		if !ac.HasScope("memories:read") {
			return nil, fmt.Errorf("missing scope memories:read")
		}
		items, err := s.Memories.List(ctx, ac.UserID, memories.ListFilter{Limit: strconv.Itoa(lim(20)), Type: str("type")})
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "get_memory":
		if !ac.HasScope("memories:read") {
			return nil, fmt.Errorf("missing scope memories:read")
		}
		id := str("id")
		if id == "" {
			return nil, fmt.Errorf("id is required")
		}
		return s.Memories.Get(ctx, ac.UserID, id)
	case "list_open_actions":
		if !ac.HasScope("memories:read") {
			return nil, fmt.Errorf("missing scope memories:read")
		}
		items, err := s.Memories.ListMini(ctx, ac.UserID, "", "open", strconv.Itoa(lim(25)))
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "get_daily_summary":
		if !ac.HasScope("memories:read") {
			return nil, fmt.Errorf("missing scope memories:read")
		}
		d := str("date")
		if d == "" {
			return nil, fmt.Errorf("date is required")
		}
		return memories.GetDailySummary(ctx, s.Memories.DB, ac.UserID, d)
	default:
		return nil, fmt.Errorf("unknown tool: %s", name)
	}
}
