package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
)

type Engine struct {
	DB       *dbx.DB
	Cfg      func() config.Config
	Provider *ProviderClient
}

func (e *Engine) cfg() config.Config {
	if e.Cfg != nil {
		return e.Cfg()
	}
	return config.Config{}
}

func (e *Engine) Ready(ctx context.Context) bool {
	return e != nil && e.Provider != nil && e.Provider.Ready(ctx)
}

func (e *Engine) inputBudgetChars(maxOutTokens int) int {
	c := e.cfg()
	promptToks := max(1, c.LLMContextSize-maxOutTokens-config.LLMPromptReserveTokens)
	return promptToks * 3
}

func (e *Engine) userSettings(ctx context.Context, userID string) UserSettingsSnapshot {
	if userID == "" || e.DB == nil {
		return UserSettingsSnapshot{}
	}
	rows, err := e.DB.R.QueryContext(ctx, `SELECT key, value_json FROM user_settings WHERE user_id=?
		AND key IN ('language','instructions_global','instructions_memories','instructions_summaries','instructions_ask')`, userID)
	if err != nil {
		return UserSettingsSnapshot{}
	}
	defer rows.Close()
	var out UserSettingsSnapshot
	for rows.Next() {
		var k, raw string
		if rows.Scan(&k, &raw) != nil {
			continue
		}
		var v string
		if json.Unmarshal([]byte(raw), &v) != nil {
			continue
		}
		switch k {
		case "language":
			if v != "" {
				cp := v
				out.Language = &cp
			}
		case "instructions_global":
			out.InstructionsGlobal = v
		case "instructions_memories":
			out.InstructionsMemories = v
		case "instructions_summaries":
			out.InstructionsSummaries = v
		case "instructions_ask":
			out.InstructionsAsk = v
		}
	}
	return out
}

func (e *Engine) ownerInstructions(ctx context.Context, userID, area string, msgs []Message) []Message {
	st := e.userSettings(ctx, userID)
	return WithInstructions(WithOutputLanguage(msgs, st.Language), st, area)
}

func (e *Engine) withRetries(fn func() error) error {
	retries := max(0, e.cfg().AIMaxRetries)
	var lastErr error
	for attempt := 0; attempt <= retries; attempt++ {
		err := fn()
		if err == nil {
			return nil
		}
		lastErr = err
		var ae *AIError
		if attempt == retries || !errors.As(err, &ae) || !TransientAICodes[ae.Code] {
			return err
		}
	}
	return lastErr
}

func contextWithinBudget[T any](items []T, budgetChars int) []T {
	var kept []T
	used := 0
	for _, it := range items {
		b, _ := json.Marshal(it)
		if len(kept) > 0 && used+len(b) > budgetChars {
			break
		}
		kept = append(kept, it)
		used += len(b)
	}
	if kept == nil {
		return []T{}
	}
	return kept
}

func completeCoverage(sections []ConversationSection, segIDs []string) []ConversationSection {
	owner := make(map[string]int)
	for idx, sec := range sections {
		for _, id := range sec.SourceSegmentIDs {
			if _, exists := owner[id]; !exists {
				owner[id] = idx
			}
		}
	}
	running := -1
	assigned := make([]int, len(segIDs))
	firstOwner := 0
	foundFirst := false
	for i, id := range segIDs {
		if idx, ok := owner[id]; ok {
			running = idx
			if !foundFirst {
				firstOwner = idx
				foundFirst = true
			}
		}
		assigned[i] = running
	}
	for i := range assigned {
		if assigned[i] == -1 {
			assigned[i] = firstOwner
		}
	}
	var out []ConversationSection
	for idx, sec := range sections {
		var ids []string
		for pos, id := range segIDs {
			if assigned[pos] == idx {
				ids = append(ids, id)
			}
		}
		if len(ids) > 0 {
			sec.SourceSegmentIDs = ids
			out = append(out, sec)
		}
	}
	return out
}

func mergeWindow(merged *ConsolidationOutput, winCount int, output ConsolidationOutput, segIDs []string) {
	prefix := fmt.Sprintf("w%d/", winCount+1)
	for _, ent := range output.Entities {
		ent.Ref = prefix + ent.Ref
		merged.Entities = append(merged.Entities, ent)
	}
	secs := completeCoverage(output.ConversationSections, segIDs)
	for i, sec := range secs {
		if i == 0 && sec.ContinuesPrevious && len(merged.ConversationSections) > 0 {
			prev := &merged.ConversationSections[len(merged.ConversationSections)-1]
			prev.TitleEn = sec.TitleEn
			prev.SummaryEn = sec.SummaryEn
			prev.Topics = sec.Topics
			prev.MemoryWorthy = sec.MemoryWorthy
			prev.SourceSegmentIDs = append(prev.SourceSegmentIDs, sec.SourceSegmentIDs...)
			continue
		}
		merged.ConversationSections = append(merged.ConversationSections, sec)
	}
	for i, mem := range output.Memories {
		for j := range mem.Entities {
			mem.Entities[j].Ref = prefix + mem.Entities[j].Ref
		}
		for j := range mem.MiniMemories {
			for k := range mem.MiniMemories[j].Entities {
				mem.MiniMemories[j].Entities[k].Ref = prefix + mem.MiniMemories[j].Entities[k].Ref
			}
		}
		if i == 0 && mem.ContinuesPrevious && len(merged.Memories) > 0 {
			prev := &merged.Memories[len(merged.Memories)-1]
			prev.Type = mem.Type
			prev.TitleEn = mem.TitleEn
			prev.SummaryEn = mem.SummaryEn
			prev.Emoji = mem.Emoji
			prev.Importance = mem.Importance
			prev.Topics = mem.Topics
			seenCM := make(map[string]bool)
			var combined []string
			for _, id := range append(prev.ContinuesMemoryIDs, mem.ContinuesMemoryIDs...) {
				if !seenCM[id] {
					seenCM[id] = true
					combined = append(combined, id)
				}
			}
			prev.ContinuesMemoryIDs = combined
			prev.SourceSegmentIDs = append(prev.SourceSegmentIDs, mem.SourceSegmentIDs...)
			prev.Entities = append(prev.Entities, mem.Entities...)
			prev.MiniMemories = append(prev.MiniMemories, mem.MiniMemories...)
			continue
		}
		merged.Memories = append(merged.Memories, mem)
	}
}

func (e *Engine) WriteDailySummary(ctx context.Context, userID string, sections []ConversationSection, prev *PreviousDailySummary, timezone string) (*DailySummaryOutput, error) {
	c := e.cfg()
	budget := max(1, e.inputBudgetChars(c.AIPreviewMaxOutTokens)-2000)
	bounded := contextWithinBudget(sections, budget)
	var occ []map[string]any
	for _, s := range bounded {
		occ = append(occ, map[string]any{"titleEn": s.TitleEn, "summaryEn": s.SummaryEn, "topics": s.Topics})
	}
	var prevDesc any
	if prev != nil {
		prevDesc = prev.SummaryEn
	}
	ub, _ := json.Marshal(map[string]any{
		"timezone":       timezone,
		"describedSoFar": prevDesc,
		"occasions":      occ,
		"outputContract": map[string]any{"summaryEn": "summary of the whole day, in the output language"},
	})
	msgs := []Message{
		{Role: "system", Content: `You maintain a running summary of one day for a personal memory service. Return one JSON object matching the supplied contract. You are given the description of the day written so far, if there is one, and the occasions recorded since. Produce the summary of the WHOLE day in the output language, preserving proper names and returning no prose outside JSON.`},
		{Role: "user", Content: string(ub)},
	}
	var out DailySummaryOutput
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "consolidation",
			Messages:  e.ownerInstructions(ctx, userID, "summaries", msgs),
			MaxTokens: c.AIPreviewMaxOutTokens,
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_daily_summary", "strict": true, "schema": DailySummaryJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		if uerr := json.Unmarshal(resp.Raw, &out); uerr != nil || strings.TrimSpace(out.SummaryEn) == "" {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Daily summary output invalid."}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

func (e *Engine) Consolidate(ctx context.Context, userID string, in ConsolidationInput) (ConsolidationResult, error) {
	c := e.cfg()
	refs := buildCompactInput(in.Conversations, in.Timezone, in.ContinuationCandidates)
	contLen := jsonLen(refs.CompactContinuationCandidates)
	winChars := min(c.ConsolidationWindowChars, max(1, e.inputBudgetChars(c.AIConsolidationMaxOutTokens)-contLen))
	windows := windowConversations(refs.CompactConversations, winChars)

	contIDs := make([]string, len(refs.CompactContinuationCandidates))
	for i, mc := range refs.CompactContinuationCandidates {
		contIDs[i] = mc.ID
	}

	var merged ConsolidationOutput
	var lastReqID string
	for winIdx, wConvs := range windows {
		var segIDs []string
		for _, conv := range wConvs {
			for _, seg := range conv.Segments {
				segIDs = append(segIDs, seg.ID)
			}
		}
		var carry *windowCarryOver
		if winIdx > 0 {
			carry = buildCarryOver(&merged)
		}
		msgs := e.ownerInstructions(ctx, userID, "memories",
			consolidationMessages(wConvs, refs.CompactContinuationCandidates, in.PreviousDailySummary, in.Timezone, carry))
		schema := ConsolidationJsonSchemaFor(segIDs, contIDs)

		var winOut ConsolidationOutput
		var winReqID string
		err := e.withRetries(func() error {
			resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
				UserID:    userID,
				Purpose:   "consolidation",
				Messages:  msgs,
				MaxTokens: c.AIConsolidationMaxOutTokens,
				ResponseFormat: map[string]any{
					"type":        "json_schema",
					"json_schema": map[string]any{"name": "neorecall_memory_consolidation", "strict": true, "schema": schema},
				},
			})
			if err != nil {
				return err
			}
			winReqID = resp.RequestID
			winOut = ConsolidationOutput{}
			if uerr := json.Unmarshal(resp.Raw, &winOut); uerr != nil {
				e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
				return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Consolidation output invalid JSON."}
			}
			if verr := ValidateAndNormalizeConsolidation(&winOut); verr != nil {
				code := "AI_SCHEMA_INVALID"
				var ae *AIError
				if errors.As(verr, &ae) {
					code = ae.Code
				}
				e.Provider.MarkValidationFailed(ctx, resp.RequestID, code)
				return &AIError{Code: code, RequestID: resp.RequestID, Message: verr.Error()}
			}
			return nil
		})
		if err != nil {
			return ConsolidationResult{}, err
		}
		lastReqID = winReqID
		mergeWindow(&merged, winIdx, winOut, segIDs)
	}

	var worthy []ConversationSection
	for _, s := range merged.ConversationSections {
		if s.MemoryWorthy {
			worthy = append(worthy, s)
		}
	}
	if len(worthy) > 0 {
		ds, err := e.WriteDailySummary(ctx, userID, worthy, in.PreviousDailySummary, in.Timezone)
		if err != nil {
			return ConsolidationResult{}, err
		}
		merged.DailySummary = ds
	}

	// Restore real segment & memory IDs.
	resolveSeg := func(al string) string {
		if realID, ok := refs.ReverseSegmentAliases[al]; ok {
			return realID
		}
		return al
	}
	resolveMem := func(al string) string {
		if realID, ok := refs.ReverseMemoryAliases[al]; ok {
			return realID
		}
		return al
	}
	for i := range merged.ConversationSections {
		for j, id := range merged.ConversationSections[i].SourceSegmentIDs {
			merged.ConversationSections[i].SourceSegmentIDs[j] = resolveSeg(id)
		}
	}
	for i := range merged.Memories {
		for j, id := range merged.Memories[i].ContinuesMemoryIDs {
			merged.Memories[i].ContinuesMemoryIDs[j] = resolveMem(id)
		}
		for j, id := range merged.Memories[i].SourceSegmentIDs {
			merged.Memories[i].SourceSegmentIDs[j] = resolveSeg(id)
		}
		for j := range merged.Memories[i].MiniMemories {
			for k, id := range merged.Memories[i].MiniMemories[j].SourceSegmentIDs {
				merged.Memories[i].MiniMemories[j].SourceSegmentIDs[k] = resolveSeg(id)
			}
		}
	}
	return ConsolidationResult{
		Value:           merged,
		RequestID:       lastReqID,
		Windows:         len(windows),
		SpeakerClusters: refs.ReverseSpeakerAliases,
	}, nil
}

func (e *Engine) PreviewConversation(ctx context.Context, userID string, conv InputConversation, prev *PreviewOutput, timezone string) (PreviewOutput, string, error) {
	refs := buildCompactInput([]InputConversation{conv}, timezone, nil)
	comp := refs.CompactConversations[0]
	for i := range comp.Segments {
		comp.Segments[i].ID = ""
	}
	cont := prev != nil
	sys := "You describe a conversation that is still being recorded. Return one JSON object matching the supplied contract.\n"
	if cont {
		sys = "You maintain the description of a conversation that is still being recorded. Carry forward everything from the earlier summary that still holds and fold in new speech.\n"
	}
	sys += "titleEn, summaryEn and topics MUST be in the output language. " + titleGuidance + "\nReturn no prose outside JSON."
	uMap := map[string]any{
		"timezone":     timezone,
		"conversation": comp,
		"outputContract": map[string]any{
			"titleEn": "Concise specific title", "summaryEn": "Faithful summary", "memoryWorthy": true, "topics": []string{"topic"},
		},
	}
	if prev != nil {
		uMap["describedSoFar"] = map[string]any{"titleEn": prev.TitleEn, "summaryEn": prev.SummaryEn, "topics": prev.Topics}
	}
	ub, _ := json.Marshal(uMap)
	msgs := e.ownerInstructions(ctx, userID, "summaries", []Message{
		{Role: "system", Content: sys},
		{Role: "user", Content: string(ub)},
	})
	resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
		UserID:    userID,
		Purpose:   "conversation_preview",
		Messages:  msgs,
		MaxTokens: e.cfg().AIPreviewMaxOutTokens,
		ResponseFormat: map[string]any{
			"type":        "json_schema",
			"json_schema": map[string]any{"name": "neorecall_conversation_preview", "strict": true, "schema": ConversationPreviewJsonSchema},
		},
	})
	if err != nil {
		return PreviewOutput{}, "", err
	}
	var out PreviewOutput
	if json.Unmarshal(resp.Raw, &out) != nil || strings.TrimSpace(out.TitleEn) == "" || strings.TrimSpace(out.SummaryEn) == "" {
		e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
		return PreviewOutput{}, "", &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Conversation preview invalid."}
	}
	out.TitleEn = BoundedText(out.TitleEn, TitleMaxLength)
	out.SummaryEn = BoundedText(out.SummaryEn, SummaryMaxLength)
	if len(out.Topics) > TopicMaxCount {
		out.Topics = out.Topics[:TopicMaxCount]
	}
	return out, resp.RequestID, nil
}

func (e *Engine) PlanQuery(ctx context.Context, userID, question, nowLocal, timezone string) (search.QueryPlan, error) {
	var plan search.QueryPlan
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "ask",
			MaxTokens: e.cfg().AIPreviewMaxOutTokens,
			Messages:  planQueryMessages(question, nowLocal, timezone),
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_query_plan", "strict": true, "schema": QueryPlanJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		if json.Unmarshal(resp.Raw, &plan) != nil || len(plan.SearchQueries) == 0 {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Query plan invalid."}
		}
		return nil
	})
	return plan, err
}

func (e *Engine) Answer(ctx context.Context, userID, question string, contextItems []map[string]any, beforeAttempt func() error, frame map[string]any) (string, []string, error) {
	c := e.cfg()
	reserve := c.AskPromptReserveCharacters
	budget := max(reserve, e.inputBudgetChars(c.AIPreviewMaxOutTokens)-len(question)-reserve)
	bounded := contextWithinBudget(contextItems, budget)
	if beforeAttempt != nil {
		if err := beforeAttempt(); err != nil {
			return "", nil, err
		}
	}
	var parsed struct {
		Answer    string `json:"answer"`
		Citations []struct {
			SourceID string `json:"sourceId"`
		} `json:"citations"`
	}
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "ask",
			MaxTokens: c.AIPreviewMaxOutTokens,
			Messages:  e.ownerInstructions(ctx, userID, "ask", answerMessages(question, bounded, frame)),
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_answer", "strict": true, "schema": AnswerJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		if json.Unmarshal(resp.Raw, &parsed) != nil || strings.TrimSpace(parsed.Answer) == "" {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Answer output invalid."}
		}
		return nil
	})
	if err != nil {
		return "", nil, err
	}
	cits := make([]string, 0, len(parsed.Citations))
	for _, cit := range parsed.Citations {
		if cit.SourceID != "" {
			cits = append(cits, cit.SourceID)
		}
	}
	return parsed.Answer, cits, nil
}

func (e *Engine) AnalyzeContextText(ctx context.Context, userID, name, content string) (string, string, error) {
	maximum := max(1, e.inputBudgetChars(e.cfg().AIPreviewMaxOutTokens)-2000)
	if len(content) > maximum {
		content = content[:maximum]
	}
	ub, _ := json.Marshal(map[string]any{
		"sourceName":     name,
		"content":        content,
		"outputContract": map[string]any{"descriptionEn": "Faithful concise description in the output language."},
	})
	return e.analyzeContextChat(ctx, userID, []Message{
		{Role: "system", Content: "You describe user-supplied context for a personal memory. Return one JSON object matching the contract. Never present planned material as completed. Return no prose outside JSON."},
		{Role: "user", Content: string(ub)},
	})
}

func (e *Engine) AnalyzeContextImage(ctx context.Context, userID, name, mediaType, base64Data string) (string, string, error) {
	ub, _ := json.Marshal(map[string]any{
		"sourceName":     name,
		"outputContract": map[string]any{"descriptionEn": "Faithful concise description in the output language."},
	})
	return e.analyzeContextChat(ctx, userID, []Message{
		{Role: "system", Content: "You describe a user-supplied image for a personal memory. Describe visible facts and transcribe important visible text faithfully. Return one JSON object matching the contract."},
		{Role: "user", Content: []ContentPart{
			{Type: "text", Text: string(ub)},
			{Type: "input_image", MediaType: mediaType, Data: base64Data},
		}},
	})
}

func (e *Engine) analyzeContextChat(ctx context.Context, userID string, msgs []Message) (string, string, error) {
	st := e.userSettings(ctx, userID)
	resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
		UserID:    userID,
		Purpose:   "context_analysis",
		Messages:  WithOutputLanguage(msgs, st.Language),
		MaxTokens: e.cfg().AIPreviewMaxOutTokens,
		ResponseFormat: map[string]any{
			"type":        "json_schema",
			"json_schema": map[string]any{"name": "neorecall_context_analysis", "strict": true, "schema": ContextAnalysisJsonSchema},
		},
	})
	if err != nil {
		return "", "", err
	}
	var out struct {
		DescriptionEn string `json:"descriptionEn"`
	}
	_ = json.Unmarshal(resp.Raw, &out)
	desc := strings.TrimSpace(out.DescriptionEn)
	if desc == "" {
		return "", "", &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Context analysis returned no description."}
	}
	return desc, resp.RequestID, nil
}

func (e *Engine) RewriteMergedMemory(ctx context.Context, userID string, memories []MemoryMergeInput) (MemoryMergeOutput, string, error) {
	var in []map[string]any
	for i, m := range memories {
		var emoji any
		if m.Emoji != "" {
			emoji = m.Emoji
		}
		in = append(in, map[string]any{
			"id": fmt.Sprintf("m%d", i+1), "type": m.Type, "titleEn": m.TitleEn, "summaryEn": m.SummaryEn,
			"emoji": emoji, "startedAt": m.StartedAt, "endedAt": m.EndedAt, "topics": m.Topics, "highlights": m.MiniMemories,
		})
	}
	ub, _ := json.Marshal(map[string]any{
		"memories": in,
		"outputContract": map[string]any{
			"type": strings.Join(MemoryTypes, "|"), "titleEn": "Concise title", "summaryEn": "Faithful summary", "emoji": "🤝",
		},
	})
	msgs := e.ownerInstructions(ctx, userID, "memories", []Message{
		{Role: "system", Content: "You merge several personal episodic memories into one coherent memory.\n" + titleGuidance + "\nPrefer the most specific memory type from: " + strings.Join(MemoryTypes, "|") + ". Return no prose outside JSON."},
		{Role: "user", Content: string(ub)},
	})
	var out MemoryMergeOutput
	var reqID string
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "memory_merge",
			Messages:  msgs,
			MaxTokens: e.cfg().AIPreviewMaxOutTokens,
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_memory_merge", "strict": true, "schema": MemoryMergeJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		reqID = resp.RequestID
		if json.Unmarshal(resp.Raw, &out) != nil || strings.TrimSpace(out.TitleEn) == "" || strings.TrimSpace(out.SummaryEn) == "" {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Memory merge output invalid."}
		}
		return nil
	})
	return out, reqID, err
}

func (e *Engine) JudgeDuplicateMemories(ctx context.Context, userID string, left, right MemoryMergeInput, minutesApart int, sameStream bool) (MemoryDedupeOutput, string, error) {
	card := func(m MemoryMergeInput) map[string]any {
		var hl []string
		for _, mm := range m.MiniMemories {
			hl = append(hl, mm.TextEn)
		}
		return map[string]any{
			"type": m.Type, "titleEn": m.TitleEn, "summaryEn": m.SummaryEn,
			"startedAt": m.StartedAt, "endedAt": m.EndedAt, "topics": m.Topics, "highlights": hl,
		}
	}
	ub, _ := json.Marshal(map[string]any{
		"minutesApart":         minutesApart,
		"recordedInSameStream": sameStream,
		"first":                card(left),
		"second":               card(right),
		"outputContract":       map[string]any{"reasoning": "one sentence", "sameOccasion": false},
	})
	msgs := []Message{
		{Role: "system", Content: "You decide whether two saved memory cards describe the SAME real-world occasion or two separate occasions. Answer false whenever the two cards do not clearly show one sitting. Return no prose outside JSON."},
		{Role: "user", Content: string(ub)},
	}
	var out MemoryDedupeOutput
	var reqID string
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "memory_merge",
			Messages:  msgs,
			MaxTokens: e.cfg().AIPreviewMaxOutTokens,
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_memory_dedupe", "strict": true, "schema": MemoryDedupeJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		reqID = resp.RequestID
		if json.Unmarshal(resp.Raw, &out) != nil || strings.TrimSpace(out.Reasoning) == "" {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Duplicate-memory output invalid."}
		}
		return nil
	})
	return out, reqID, err
}

func (e *Engine) TestLLM(ctx context.Context) map[string]any {
	rt := e.Provider.Providers.ResolveWorkload(ctx, "llm")
	started := time.Now()
	if !e.Provider.Ready(ctx) {
		return map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "error": e.Provider.DescribeNotReady(ctx)}
	}
	c := e.cfg()
	ub, _ := json.Marshal(map[string]any{"question": `Reply with the single word "ready".`, "outputContract": map[string]any{"answer": "ready"}})
	resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
		Purpose:   "ask",
		MaxTokens: c.AIPreviewMaxOutTokens,
		Messages: []Message{
			{Role: "system", Content: "You answer with one JSON object matching the supplied contract and no prose outside it."},
			{Role: "user", Content: string(ub)},
		},
		ResponseFormat: map[string]any{
			"type": "json_schema",
			"json_schema": map[string]any{
				"name":   "neorecall_provider_test",
				"strict": true,
				"schema": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required":             []string{"answer"},
					"properties":           map[string]any{"answer": map[string]any{"type": "string", "minLength": 1}},
				},
			},
		},
	})
	ms := time.Since(started).Milliseconds()
	if err != nil {
		var code any
		var ae *AIError
		advice := ""
		if errors.As(err, &ae) {
			code = ae.Code
			if ae.Code == "AI_OUTPUT_TRUNCATED" {
				advice = fmt.Sprintf(" Raise AI_PREVIEW_MAX_OUTPUT_TOKENS (now %d) and AI_CONSOLIDATION_MAX_OUTPUT_TOKENS, or turn off thinking mode.", c.AIPreviewMaxOutTokens)
			}
		}
		return map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "ms": ms, "error": err.Error() + advice, "code": code}
	}
	var out struct {
		Answer string `json:"answer"`
	}
	_ = json.Unmarshal(resp.Raw, &out)
	return map[string]any{"ok": true, "provider": rt.Provider, "model": rt.Model, "ms": ms, "answer": out.Answer}
}

type RewriteContextOutput struct {
	Type                 string                    `json:"type"`
	TitleEn              string                    `json:"titleEn"`
	SummaryEn            string                    `json:"summaryEn"`
	Emoji                string                    `json:"emoji"`
	Importance           float64                   `json:"importance"`
	Topics               []string                  `json:"topics"`
	SourceContextItemIDs []string                  `json:"sourceContextItemIds"`
	MiniMemories         []ConsolidationMiniMemory `json:"miniMemories"`
}

func (e *Engine) RewriteMemoryWithContext(ctx context.Context, userID string, mem RewriteContextMemory, segs []RewriteContextSegment, items []RewriteContextItem) (RewriteContextOutput, string, error) {
	msgs := e.ownerInstructions(ctx, userID, "memories", rewriteMemoryContextMessages(mem, segs, items))
	validCtxIDs := make(map[string]bool, len(items))
	for _, item := range items {
		validCtxIDs[item.ID] = true
	}
	validSegIDs := make(map[string]bool, len(segs))
	for _, seg := range segs {
		validSegIDs[seg.PublicID] = true
	}
	var out RewriteContextOutput
	var reqID string
	err := e.withRetries(func() error {
		resp, err := e.Provider.ChatJSON(ctx, ChatRequest{
			UserID:    userID,
			Purpose:   "memory_context_rewrite",
			Messages:  msgs,
			MaxTokens: e.cfg().AIConsolidationMaxOutTokens,
			ResponseFormat: map[string]any{
				"type":        "json_schema",
				"json_schema": map[string]any{"name": "neorecall_memory_context_rewrite", "strict": true, "schema": MemoryContextRewriteJsonSchema},
			},
		})
		if err != nil {
			return err
		}
		reqID = resp.RequestID
		if json.Unmarshal(resp.Raw, &out) != nil || strings.TrimSpace(out.TitleEn) == "" || strings.TrimSpace(out.SummaryEn) == "" {
			e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_SCHEMA_INVALID")
			return &AIError{Code: "AI_SCHEMA_INVALID", RequestID: resp.RequestID, Message: "Memory context rewrite output invalid."}
		}
		if out.Importance < 1 {
			out.Importance = 1
		} else if out.Importance > 10 {
			out.Importance = 10
		}
		out.TitleEn = BoundedText(out.TitleEn, TitleMaxLength)
		out.SummaryEn = BoundedText(out.SummaryEn, SummaryMaxLength)
		if strings.TrimSpace(out.Emoji) == "" {
			out.Emoji = DefaultEmojiForType(out.Type)
		}
		var keptIDs []string
		for _, id := range out.SourceContextItemIDs {
			if validCtxIDs[id] {
				keptIDs = append(keptIDs, id)
			}
		}
		out.SourceContextItemIDs = keptIDs
		var keptMini []ConsolidationMiniMemory
		for _, mm := range out.MiniMemories {
			if strings.TrimSpace(mm.TextEn) == "" {
				continue
			}
			var segsKept []string
			for _, sid := range mm.SourceSegmentIDs {
				if validSegIDs[sid] {
					segsKept = append(segsKept, sid)
				}
			}
			mm.SourceSegmentIDs = segsKept
			iso, terr := normalizeTemporalRef(mm.DueAt)
			if terr != nil {
				e.Provider.MarkValidationFailed(ctx, resp.RequestID, "AI_TEMPORAL_INVALID")
				return &AIError{Code: "AI_TEMPORAL_INVALID", RequestID: resp.RequestID, Message: terr.Error()}
			}
			mm.DueAtISO = iso
			keptMini = append(keptMini, mm)
		}
		out.MiniMemories = keptMini
		return nil
	})
	return out, reqID, err
}
