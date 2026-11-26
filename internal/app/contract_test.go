package app_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/app"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

type client struct {
	t     *testing.T
	a     *app.App
	token string
}

// call sends one request through the assembled handler and checks the status.
func (c client) call(method, path string, want int, body io.Reader, headers ...string) map[string]any {
	c.t.Helper()
	req := httptest.NewRequest(method, path, body)
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	rec := httptest.NewRecorder()
	c.a.Handler.ServeHTTP(rec, req)
	if rec.Code != want {
		c.t.Fatalf("%s %s: status %d, want %d: %s", method, path, rec.Code, want, rec.Body.String())
	}
	var out map[string]any
	if strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") && rec.Body.Len() > 0 {
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			c.t.Fatalf("%s %s: %v", method, path, err)
		}
	}
	return out
}

func (c client) json(method, path string, want int, body string) map[string]any {
	c.t.Helper()
	return c.call(method, path, want, strings.NewReader(body))
}

func (c client) multipart(method, path string, want int, fields map[string]string, fileField, filename string, content []byte, headers ...string) map[string]any {
	c.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		_ = mw.WriteField(k, v)
	}
	if fileField != "" {
		fw, err := mw.CreateFormFile(fileField, filename)
		if err != nil {
			c.t.Fatal(err)
		}
		_, _ = fw.Write(content)
	}
	_ = mw.Close()
	return c.call(method, path, want, &buf, append(headers, "Content-Type", mw.FormDataContentType())...)
}

func has(t *testing.T, value any, keys ...string) map[string]any {
	t.Helper()
	object, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("not an object: %v", value)
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			t.Fatalf("missing %q in %v", key, object)
		}
	}
	return object
}

func wav(seconds int) []byte {
	data := make([]byte, seconds*16000*2)
	for i := 0; i < len(data); i += 2 {
		binary.LittleEndian.PutUint16(data[i:], uint16((i%200)*100))
	}
	var b bytes.Buffer
	b.WriteString("RIFF")
	_ = binary.Write(&b, binary.LittleEndian, uint32(36+len(data)))
	b.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(16), uint16(1), uint16(1), uint32(16000), uint32(32000), uint16(2), uint16(16)} {
		_ = binary.Write(&b, binary.LittleEndian, v)
	}
	b.WriteString("data")
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(data)))
	b.Write(data)
	return b.Bytes()
}

func TestAssembledServerKeepsTheShippedContract(t *testing.T) {
	ctx := context.Background()
	var transcriptions atomic.Int32
	// One loopback server stands in for the transcription service and for a
	// Nextcloud on the user's own network.
	var lan *httptest.Server
	lan = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/audio/transcriptions":
			transcriptions.Add(1)
			w.WriteHeader(http.StatusInternalServerError)
		case "/index.php/login/v2":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"login":"%s/login","poll":{"token":"t","endpoint":"%s/poll"}}`, lan.URL, lan.URL)
		default:
			http.NotFound(w, r)
		}
	}))
	defer lan.Close()

	home := t.TempDir()
	getenv := func(k string) string {
		switch k {
		case "NEORECALL_HOME":
			return home
		case "TRANSCRIPTION_API_BASE_URL":
			return lan.URL + "/v1"
		case "TRANSCRIPTION_API_MODEL":
			return "whisper"
		}
		return ""
	}
	cfg, err := config.Load(getenv, home, home)
	if err != nil {
		t.Fatal(err)
	}
	a, err := app.Open(ctx, app.Options{StaticConfig: &cfg, Getenv: getenv, Version: "9.9.9"})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()

	// The app's sign-in.
	anonymous := client{t: t, a: a}
	registered := anonymous.json("POST", "/api/v1/auth/register", 201, `{"username":"owner","password":"Orchid-Tram-58-Lagoon"}`)
	userID := registered["user"].(map[string]any)["id"].(string)
	anonymous.json("POST", "/api/v1/auth/login", 200, `{"account":"owner","password":"Orchid-Tram-58-Lagoon"}`)
	c := client{t: t, a: a, token: registered["session"].(map[string]any)["token"].(string)}
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := a.DB.W.ExecContext(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`UPDATE users SET role='admin' WHERE id=?`, userID)

	// Audio import, from declaration to queued transcription.
	audio := wav(2)
	sum := sha256.Sum256(audio)
	digest := hex.EncodeToString(sum[:])
	importID := "11111111-1111-4111-8111-111111111111"
	declare := fmt.Sprintf(`{"id":"%s","originalName":"talk.wav","contentType":"audio/wav","totalSize":%d,"sha256":"%s"}`, importID, len(audio), digest)
	has(t, c.json("POST", "/api/v1/imports", 201, declare), "id", "state", "original_name", "missingParts", "parts", "error_code")
	c.multipart("PUT", "/api/v1/imports/"+importID+"/parts/0", 200, nil, "part", "part", audio,
		"Content-Range", fmt.Sprintf("bytes 0-%d/%d", len(audio)-1, len(audio)), "X-Part-Sha256", digest)
	c.json("POST", "/api/v1/imports/"+importID+"/complete", 202, ``)
	c.json("GET", "/api/v1/imports/"+importID, 200, ``)

	if transcription.ResolveFFmpegPath() != "" {
		chunk := func() (state, path string) {
			if err := a.DB.R.QueryRowContext(ctx, `SELECT state, temporary_path FROM audio_chunks`).Scan(&state, &path); err != nil {
				t.Fatal(err)
			}
			return state, path
		}
		run := func() {
			t.Helper()
			exec(`UPDATE jobs SET next_attempt_at='2000-01-01T00:00:00.000Z' WHERE status='queued'`)
			if _, err := a.Runner.RunOnce(ctx, "test"); err != nil {
				t.Fatal(err)
			}
		}
		run() // process_import
		exec(`UPDATE jobs SET status='cancelled' WHERE type!='transcribe_chunk' AND status='queued'`)
		run() // the provider answers 500
		state, path := chunk()
		if _, err := os.Stat(path); err != nil || state != "retryable_failed" || transcriptions.Load() != 1 {
			t.Fatalf("after provider error: state=%s calls=%d err=%v", state, transcriptions.Load(), err)
		}
		// An audio file the server cannot read right now is not thrown away.
		if err := os.Chmod(path, 0); err != nil {
			t.Fatal(err)
		}
		run()
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatalf("unreadable audio was removed: %v", err)
		}
		if state, _ := chunk(); state != "retryable_failed" {
			t.Fatalf("unreadable audio: state=%s", state)
		}
	}
	c.json("DELETE", "/api/v1/imports/"+importID, 204, ``)

	// Recording and memory context, as the app and firmware send it.
	exec(`INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES ('dev', ?, 'dev', 'Phone', 'ios', 'mobile')`, userID)
	exec(`INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
		VALUES ('sess', ?, 'dev', 'sess', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'active')`, userID)
	exec(`INSERT INTO consolidation_runs (id, user_id, state, reserved_at) VALUES ('run', ?, 'succeeded', '2026-04-01T11:00:00.000Z')`, userID)
	exec(`INSERT INTO memories (public_id, user_id, type, title_en, summary_en, importance, started_at, ended_at, consolidation_run_id)
		VALUES ('mem', ?, 'meeting', 'Plan', 'A plan', 5, '2026-04-01T10:00:00.000Z', '2026-04-01T11:00:00.000Z', 'run')`, userID)
	exec(`INSERT INTO mini_memories (public_id, user_id, memory_id, kind, text_en, importance, confidence, status)
		VALUES ('mini', ?, (SELECT id FROM memories), 'task', 'Send it', 5, 1, 'open')`, userID)

	itemFields := []string{"id", "kind", "sessionId", "memoryId", "capturedOffsetMs", "noteText", "originalName", "originalAvailable", "analysisState", "usedByAi", "createdAt"}
	for i, base := range []string{"/api/v1/ingest/sessions/sess/context", "/api/v1/memories/mem/context"} {
		note := fmt.Sprintf("%s/22222222-2222-4222-8222-22222222222%d", base, i)
		fields := map[string]string{"kind": "note", "noteText": "remember", "capturedOffsetMs": "5000"}
		first := has(t, c.multipart("PUT", note, 201, fields, "", "", nil)["item"], itemFields...)
		again := c.multipart("PUT", note, 201, fields, "", "", nil)["item"].(map[string]any)
		if first["id"] != again["id"] || !strings.HasSuffix(note, first["id"].(string)) {
			t.Fatalf("upload is not idempotent: %v %v", first, again)
		}
		if got := c.json("PATCH", note, 200, `{"noteText":"edited"}`)["item"].(map[string]any); got["noteText"] != "edited" {
			t.Fatalf("patch: %v", got)
		}
		file := fmt.Sprintf("%s/33333333-3333-4333-8333-33333333333%d", base, i)
		c.multipart("PUT", file, 201, map[string]string{"kind": "document", "capturedOffsetMs": "1", "contentType": "text/plain"}, "file", "a.txt", []byte("hello"))
		c.json("GET", file+"/original", 200, ``)
		has(t, c.json("POST", file+"/retry", 202, ``)["item"], itemFields...)
		if items := c.json("GET", base, 200, ``)["items"].([]any); len(items) != 2 {
			t.Fatalf("context list: %v", items)
		}
		c.json("DELETE", file, 204, ``)
	}
	// An item is only reachable through the recording or memory that owns it.
	c.json("DELETE", "/api/v1/memories/mem/context/22222222-2222-4222-8222-222222222220", 404, ``)

	detail := has(t, c.json("GET", "/api/v1/memories/mem", 200, ``), "id", "public_id", "mini_count", "miniMemories", "contextItems")
	has(t, detail["contextItems"].([]any)[0], itemFields...)
	mini := has(t, c.json("GET", "/api/v1/memories/mini", 200, ``)["items"].([]any)[0], "id", "public_id", "user_id", "memory_id", "memory", "timeline_at")
	if _, ok := mini["id"].(float64); !ok {
		t.Fatalf("mini id: %v", mini["id"])
	}
	c.json("PATCH", "/api/v1/memories/mini/mini", 200, `{"status":"completed"}`)
	c.json("DELETE", "/api/v1/memories/mini/mini", 204, ``)
	has(t, c.json("GET", "/api/v1/memories/daily-summaries", 200, ``), "items")
	has(t, c.json("GET", "/api/v1/memories/consolidations/latest", 200, ``), "run", "eligibility")
	has(t, c.json("POST", "/api/v1/memories/consolidations", 503, `{}`), "error")

	// Stored sources stay visible and removable; their secrets stay hidden.
	exec(`INSERT INTO sources (id, user_id, type, name, config_json, enabled) VALUES ('src', ?, 'discord', 'Bot', '{"token":"secret","guildId":"g"}', 1)`, userID)
	listed := c.json("GET", "/api/v1/sources", 200, ``)["sources"].([]any)[0].(map[string]any)
	if listed["config"].(map[string]any)["token"] == "secret" || listed["enabled"] != true {
		t.Fatalf("source: %v", listed)
	}
	c.json("PATCH", "/api/v1/sources/src", 200, `{"enabled":false,"name":"Old bot","config":{"token":"••••••••"}}`)
	var stored string
	if err := a.DB.R.QueryRowContext(ctx, `SELECT config_json FROM sources`).Scan(&stored); err != nil || !strings.Contains(stored, "secret") {
		t.Fatalf("secret lost: %s %v", stored, err)
	}
	c.json("POST", "/api/v1/sources", 410, `{"type":"discord","name":"New"}`)
	c.json("DELETE", "/api/v1/sources/src", 204, ``)

	// Admin page.
	stats := has(t, c.json("GET", "/api/v1/admin/stats", 200, ``), "version", "users", "devices", "recordings", "queue", "oldestQueuedAt", "workers", "temporaryAudioBytes", "cleanupPending", "vector", "ai", "processing")
	if stats["version"] != "9.9.9" {
		t.Fatalf("version: %v", stats["version"])
	}
	has(t, c.json("GET", "/api/v1/admin/users", 200, ``)["users"].([]any)[0], "device_count", "recording_count", "disabled_at")
	has(t, c.json("PATCH", "/api/v1/admin/users/"+userID, 403, `{"disabled":true}`), "error")
	has(t, c.json("POST", "/api/v1/admin/backups/run", 200, ``), "id", "key", "bytes", "checksum")
	backups := has(t, c.json("GET", "/api/v1/admin/backups", 200, ``), "status", "history")
	has(t, backups["status"], "enabled", "destination", "location", "unreachable", "intervalHours", "retain", "running", "due", "nextDueAt", "lastSuccessAt", "artifactCount", "artifactBytes")
	has(t, backups["history"].([]any)[0], "started_at", "trigger_kind", "state", "artifact_key", "bytes", "pruned_at")

	// A Nextcloud on the same network can be connected.
	started := c.json("POST", "/api/v1/cloud/nextcloud/login", 200, `{"instanceUrl":"`+lan.URL+`"}`)
	if !strings.Contains(fmt.Sprint(started), lan.URL+"/login") {
		t.Fatalf("nextcloud login: %v", started)
	}

	// MCP takes OAuth tokens only; its conversation tools are wired.
	c.json("POST", "/mcp", 401, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	a.Authenticator.OAuth = func(_ context.Context, token string) *auth.AuthContext {
		if token != "nro_test" {
			return nil
		}
		return &auth.AuthContext{Type: "oauth", UserID: userID, Scopes: []string{"recordings:read", "memories:read", "search:read"}}
	}
	mcp := client{t: t, a: a, token: "nro_test"}
	for _, call := range []string{`list_conversations","arguments":{}`, `list_memories","arguments":{"q":"plan"}`, `list_daily_summaries","arguments":{}`, `search","arguments":{"query":"plan"}`} {
		reply := mcp.json("POST", "/mcp", 200, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"`+call+`}}`)
		if result := has(t, reply["result"], "content"); result["isError"] != nil {
			t.Fatalf("%s: %v", call, result)
		}
	}
}
