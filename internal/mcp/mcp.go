package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
)

type Server struct {
	Auth          *auth.Authenticator
	Search        *search.Service
	Memories      *memories.Service
	Conversations *conversations.Service
	Log           *slog.Logger
	Version       string
}

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	scope       string
}

const protocolVersion = "2025-03-26"

var (
	limitSchema    = map[string]any{"type": "integer", "minimum": 1, "maximum": 100}
	stringSchema   = map[string]any{"type": "string"}
	requiredString = map[string]any{"type": "string", "minLength": 1}
)

func objectSchema(properties map[string]any, required ...string) map[string]any {
	schema := map[string]any{"type": "object", "additionalProperties": false, "properties": properties}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// Tool names, scopes and schemas are a public contract with connected MCP
// clients; every tool is read-only and none of them invokes Ask.
var mcpTools = []toolDef{
	{
		Name:        "search",
		Description: "Hybrid keyword and semantic search over memories and transcript evidence. Does not invoke NeoRecall Ask.",
		scope:       "search:read",
		InputSchema: objectSchema(map[string]any{
			"query": requiredString, "limit": limitSchema,
			"kinds": map[string]any{"type": "array", "items": stringSchema},
		}, "query"),
	},
	{
		Name:        "list_memories",
		Description: "List episodic memories for this account.",
		scope:       "memories:read",
		InputSchema: objectSchema(map[string]any{
			"limit": limitSchema, "q": stringSchema, "from": stringSchema, "to": stringSchema, "type": stringSchema,
		}),
	},
	{
		Name:        "get_memory",
		Description: "Read one memory, including mini-memories, entities, and transcript sources. Audio is never included.",
		scope:       "memories:read",
		InputSchema: objectSchema(map[string]any{"id": requiredString}, "id"),
	},
	{
		Name:        "list_mini_memories",
		Description: "List atomic mini-memories.",
		scope:       "memories:read",
		InputSchema: objectSchema(map[string]any{
			"limit": limitSchema, "q": stringSchema, "memoryId": stringSchema, "kind": stringSchema, "status": stringSchema,
		}),
	},
	{
		Name:        "list_daily_summaries",
		Description: "List incremental daily summaries.",
		scope:       "memories:read",
		InputSchema: objectSchema(map[string]any{"limit": limitSchema, "from": stringSchema, "to": stringSchema}),
	},
	{
		Name:        "list_conversations",
		Description: "List conversations (moments) with titles and summaries. Does not include full transcripts.",
		scope:       "recordings:read",
		InputSchema: objectSchema(map[string]any{"limit": limitSchema, "state": stringSchema, "from": stringSchema, "to": stringSchema}),
	},
	{
		Name:        "get_conversation",
		Description: "Read one conversation and its transcript segments. Audio is never available.",
		scope:       "recordings:read",
		InputSchema: objectSchema(map[string]any{"id": requiredString}, "id"),
	},
}

func (s *Server) Mount(mux *http.ServeMux) {
	limit := httperr.NewLimiter(time.Minute, 120, "RATE_LIMITED", func(r *http.Request) string { return auth.BearerToken(r) })
	mux.HandleFunc("POST /mcp", func(w http.ResponseWriter, r *http.Request) {
		if limit.Allow(w, r, s.Log) {
			s.handleMCP(w, r)
		}
	})
	mux.HandleFunc("GET /mcp", func(w http.ResponseWriter, r *http.Request) {
		if s.authenticate(w, r) == nil {
			return
		}
		w.Header().Set("Allow", "POST")
		httpx.WriteJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method Not Allowed"})
	})
}

// authenticate accepts only OAuth access tokens: MCP clients are third parties
// the user approved on the consent page, never sessions or API keys.
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) *auth.AuthContext {
	if tok := auth.BearerToken(r); tok != "" && s.Auth != nil && s.Auth.OAuth != nil {
		if ac := s.Auth.OAuth(r.Context(), tok); ac != nil {
			return ac
		}
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if p := firstForwarded(r, "X-Forwarded-Proto"); p != "" {
		scheme = p
	}
	host := r.Host
	if h := firstForwarded(r, "X-Forwarded-Host"); h != "" {
		host = h
	}
	w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="NeoRecall", resource_metadata="%s://%s/.well-known/oauth-protected-resource"`, scheme, host))
	httpx.WriteJSON(w, http.StatusUnauthorized, map[string]any{"error": "Unauthorized"})
	return nil
}

func firstForwarded(r *http.Request, header string) string {
	value, _, _ := strings.Cut(r.Header.Get(header), ",")
	return strings.TrimSpace(value)
}

type rpcRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      any            `json:"id"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params"`
}

func rpcError(id any, code int, message string) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}}
}

func (s *Server) handleMCP(w http.ResponseWriter, r *http.Request) {
	ac := s.authenticate(w, r)
	if ac == nil {
		return
	}
	var body json.RawMessage
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, rpcError(nil, -32700, "Parse error"))
		return
	}
	var batch []json.RawMessage
	if json.Unmarshal(body, &batch) == nil {
		replies := []map[string]any{}
		for _, item := range batch {
			if reply := s.handleRPC(r.Context(), ac, item); reply != nil {
				replies = append(replies, reply)
			}
		}
		httpx.WriteJSON(w, http.StatusOK, replies)
		return
	}
	reply := s.handleRPC(r.Context(), ac, body)
	if reply == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, reply)
}

// handleRPC answers one JSON-RPC message; nil means it was a notification.
func (s *Server) handleRPC(ctx context.Context, ac *auth.AuthContext, raw json.RawMessage) map[string]any {
	var req rpcRequest
	if err := json.Unmarshal(raw, &req); err != nil || req.JSONRPC != "2.0" || req.Method == "" {
		return rpcError(req.ID, -32600, "Invalid Request")
	}
	result := func(res any) map[string]any {
		return map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": res}
	}
	switch req.Method {
	case "initialize":
		return result(map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "neorecall", "version": s.Version},
		})
	case "notifications/initialized":
		return nil
	case "ping":
		return result(map[string]any{})
	case "tools/list":
		return result(map[string]any{"tools": mcpTools})
	case "tools/call":
		name, _ := req.Params["name"].(string)
		args, _ := req.Params["arguments"].(map[string]any)
		out, err := s.callTool(ctx, ac, strings.TrimSpace(name), args)
		failed := err != nil
		if failed {
			var he *httperr.Error
			message := "Tool call failed."
			if errors.As(err, &he) {
				message = he.Message
			} else if s.Log != nil {
				s.Log.Error("MCP tool call failed", "tool", name, "error", err)
			}
			out = map[string]any{"error": message}
		}
		text, _ := json.Marshal(out)
		content := map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}}
		if failed {
			content["isError"] = true
		}
		return result(content)
	}
	return rpcError(req.ID, -32601, "Method not found: "+req.Method)
}

func (s *Server) callTool(ctx context.Context, ac *auth.AuthContext, name string, args map[string]any) (any, error) {
	index := slices.IndexFunc(mcpTools, func(t toolDef) bool { return t.Name == name })
	if index < 0 {
		return nil, httperr.New(http.StatusNotFound, "UNKNOWN_TOOL", "Unknown tool: "+name)
	}
	tool := mcpTools[index]
	if !ac.HasScope(tool.scope) {
		return nil, httperr.New(http.StatusForbidden, "INSUFFICIENT_SCOPE", "The "+tool.scope+" scope is required.")
	}
	str := func(k string) string { v, _ := args[k].(string); return strings.TrimSpace(v) }
	required, _ := tool.InputSchema["required"].([]string)
	for _, key := range required {
		if str(key) == "" {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_PARAMS", key+" is required.")
		}
	}
	limit := ""
	if f, ok := args["limit"].(float64); ok {
		limit = strconv.Itoa(int(f))
	}
	items := func(list any, err error) (any, error) {
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": list}, nil
	}

	switch name {
	case "search":
		var kinds []string
		if raw, ok := args["kinds"].([]any); ok {
			for _, it := range raw {
				if kind, ok := it.(string); ok && kind != "" {
					kinds = append(kinds, kind)
				}
			}
		}
		count, _ := strconv.Atoi(limit)
		res, err := s.Search.Search(ctx, ac.UserID, str("query"), search.SearchOptions{Limit: count, Kinds: kinds})
		if err != nil {
			return nil, err
		}
		return res.Results, nil
	case "list_memories":
		return items(s.Memories.List(ctx, ac.UserID, memories.ListFilter{
			Limit: limit, Query: str("q"), From: str("from"), To: str("to"), Type: str("type"),
		}))
	case "get_memory":
		return s.Memories.Get(ctx, ac.UserID, str("id"))
	case "list_mini_memories":
		return items(s.Memories.ListMini(ctx, ac.UserID, str("kind"), str("status"), limit, str("memoryId"), "", str("q")))
	case "list_daily_summaries":
		return items(memories.ListDailySummaries(ctx, s.Memories.DB, ac.UserID, memories.DailyFilter{
			Limit: limit, From: str("from"), To: str("to"),
		}))
	case "list_conversations":
		return items(s.Conversations.List(ctx, ac.UserID, conversations.ListFilter{
			Limit: limit, State: str("state"), From: str("from"), To: str("to"),
		}))
	default: // get_conversation
		return s.Conversations.Get(ctx, ac.UserID, str("id"))
	}
}
