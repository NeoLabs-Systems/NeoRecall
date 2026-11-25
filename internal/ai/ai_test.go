package ai_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/providers"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

func TestWireSchemaAndEngineFlows(t *testing.T) {
	ctx := context.Background()
	stripped := ai.WireSchema(ai.ConversationPreviewJsonSchema).(map[string]any)
	props := stripped["properties"].(map[string]any)
	if _, hasMaxLen := props["titleEn"].(map[string]any)["maxLength"]; hasMaxLen {
		t.Fatal("WireSchema must strip maxLength recursively")
	}

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

	uid := "00000000-0000-0000-0000-000000000020"
	_, err = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'aiuser', 'ai@x.io', 'hash', 'admin')`, uid)
	if err != nil {
		t.Fatal(err)
	}

	callCount := 0
	mockOpenAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		rawBody, _ := io.ReadAll(r.Body)
		var reqMap map[string]any
		_ = json.Unmarshal(rawBody, &reqMap)
		bodyStr := string(rawBody)
		callCount++

		// Test 1: TestLLM hits length truncation first (no enable_thinking:false), then succeeds when enable_thinking:false is sent!
		if strings.Contains(bodyStr, `Reply with the single word`) {
			if !strings.Contains(bodyStr, `"enable_thinking":false`) {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"choices": []any{map[string]any{"finish_reason": "length", "message": map[string]any{"content": "partial"}}},
					"usage":   map[string]any{"prompt_tokens": 10, "completion_tokens": 50},
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []any{map[string]any{"finish_reason": "stop", "message": map[string]any{"content": `{"answer":"ready"}`}}},
				"usage":   map[string]any{"prompt_tokens": 10, "completion_tokens": 5},
			})
			return
		}

		// Test 2: Schema rejected triggers json_object fallback.
		if rf, ok := reqMap["response_format"].(map[string]any); ok && rf["type"] == "json_schema" && strings.Contains(bodyStr, "Preview convo") {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"unsupported json_schema grammar"}}`))
			return
		}
		if strings.Contains(bodyStr, "Preview convo") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []any{map[string]any{"finish_reason": "stop", "message": map[string]any{"content": `{"titleEn":"Standup Sync","summaryEn":"Synced on sprint goals.","memoryWorthy":true,"topics":["sprint"]}`}}},
			})
			return
		}

		// Test 3: Consolidation returns entity + memory using alias e1 and seg s1.
		if strings.Contains(bodyStr, "consolidate personal transcripts") {
			respJSON := map[string]any{
				"conversationSections": []any{map[string]any{
					"titleEn": "Budget Review", "summaryEn": "Alice approved Q4 budget.", "memoryWorthy": true,
					"continuesPrevious": false, "topics": []string{"budget"}, "sourceSegmentIds": []string{"s1"},
				}},
				"entities": []any{map[string]any{
					"ref": "e1", "kind": "person", "canonicalNameEn": "Alice", "displayName": "Alice", "aliases": []any{}, "speakerAlias": "speaker1",
				}},
				"memories": []any{map[string]any{
					"type": "decision", "continuesPrevious": false, "continuationReasoning": nil, "continuesMemoryIds": []string{},
					"titleEn": "Q4 Budget Approved", "summaryEn": "Alice approved Q4 budget.", "emoji": "⚖️", "importance": 8,
					"sourceSegmentIds": []string{"s1"}, "topics": []string{"budget"},
					"entities": []any{map[string]any{"ref": "e1", "role": "participant"}},
					"miniMemories": []any{map[string]any{
						"kind": "task", "textEn": "Send final spreadsheet", "importance": 7, "confidence": 0.9,
						"dueAt": "2026-10-05T12:00:00Z", "occurredAt": nil, "status": "open",
						"sourceSegmentIds": []string{"s1"}, "entities": []any{map[string]any{"ref": "e1", "role": "owner"}},
					}},
				}},
				"dailySummary": nil,
			}
			b, _ := json.Marshal(respJSON)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []any{map[string]any{"finish_reason": "stop", "message": map[string]any{"content": string(b)}}},
				"usage":   map[string]any{"prompt_tokens": 120, "completion_tokens": 80},
			})
			return
		}

		// Test 4: RewriteMemoryWithContext
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []any{map[string]any{"finish_reason": "stop", "message": map[string]any{
				"content": `{"type":"decision","titleEn":"Updated Budget","summaryEn":"Includes attached PDF figures.","emoji":"📊","importance":9,"topics":["budget"],"sourceContextItemIds":["ctx-uuid-1"],"miniMemories":[]}`,
			}}},
		})
	}))
	defer mockOpenAI.Close()

	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	provSvc := &providers.Service{
		DB:        db,
		Cfg:       func() config.Config { return cfg },
		MasterKey: keyFn,
		HTTP:      mockOpenAI.Client(),
		Log:       log,
	}
	baseURL := mockOpenAI.URL
	model := "local-qwen"
	if _, err := provSvc.Update(ctx, map[string]providers.WorkloadUpdate{
		"llm": {Provider: "openai_compatible", BaseURL: &baseURL, Model: &model, APIKey: "sk-test"},
	}); err != nil {
		t.Fatal(err)
	}

	pc := &ai.ProviderClient{
		DB:        db,
		Cfg:       func() config.Config { return cfg },
		Providers: provSvc,
		Usage:     &usage.Service{DB: db},
		HTTP:      mockOpenAI.Client(),
		Log:       log,
	}
	eng := &ai.Engine{DB: db, Cfg: func() config.Config { return cfg }, Provider: pc}

	testRes := eng.TestLLM(ctx)
	if ok, _ := testRes["ok"].(bool); !ok {
		t.Fatalf("expected TestLLM ok after NO_THINKING retry, got %+v", testRes)
	}

	prev, _, err := eng.PreviewConversation(ctx, uid, ai.InputConversation{
		ID: "conv-1", StartedAt: "2026-10-01T10:00:00Z", EndedAt: "2026-10-01T10:05:00Z",
		Segments: []ai.InputSegment{{ID: "seg-1", Text: "Preview convo transcript"}},
	}, nil, "UTC")
	if err != nil || prev.TitleEn != "Standup Sync" {
		t.Fatalf("PreviewConversation failed: prev=%+v err=%v", prev, err)
	}

	sp1 := "speaker-cluster-uuid"
	cons, err := eng.Consolidate(ctx, uid, ai.ConsolidationInput{
		Timezone: "UTC",
		Conversations: []ai.InputConversation{{
			ID: "conv-1", StartedAt: "2026-10-01T10:00:00Z", EndedAt: "2026-10-01T10:05:00Z",
			Segments: []ai.InputSegment{{ID: "real-seg-uuid", StartedAt: "2026-10-01T10:00:00Z", EndedAt: "2026-10-01T10:01:00Z", Text: "Let's approve budget", SpeakerClusterID: &sp1}},
		}},
	})
	if err != nil {
		t.Fatalf("Consolidate error: %v", err)
	}
	if cons.Value.Memories[0].SourceSegmentIDs[0] != "real-seg-uuid" {
		t.Fatalf("expected s1 restored to real-seg-uuid, got %+v", cons.Value.Memories[0].SourceSegmentIDs)
	}
	if cons.SpeakerClusters["speaker1"] != sp1 {
		t.Fatalf("expected speaker cluster mapped, got %+v", cons.SpeakerClusters)
	}

	rw, _, err := eng.RewriteMemoryWithContext(ctx, uid, ai.RewriteContextMemory{
		Type: "decision", TitleEn: "Q4 Budget Approved", SummaryEn: "Alice approved.", Emoji: "⚖️", Importance: 8, StartedAt: "2026-10-01T10:00:00Z", EndedAt: "2026-10-01T10:05:00Z",
	}, []ai.RewriteContextSegment{{PublicID: "real-seg-uuid", Text: "Let's approve budget"}}, []ai.RewriteContextItem{
		{ID: "ctx-uuid-1", Kind: "note", CapturedAt: "2026-10-01T10:02:00Z", Content: "Final number: $40k"},
	})
	if err != nil || rw.TitleEn != "Updated Budget" || len(rw.SourceContextItemIDs) != 1 || rw.SourceContextItemIDs[0] != "ctx-uuid-1" {
		t.Fatalf("RewriteMemoryWithContext unexpected: rw=%+v err=%v", rw, err)
	}
	if callCount < 5 {
		t.Fatalf("expected >=5 HTTP mock calls (incl retries), got %d", callCount)
	}
}
