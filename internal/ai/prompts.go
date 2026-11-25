package ai

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

const titleGuidance = `Write the title from the human subject and purpose of the speech, not from the capture process.
Infer the most specific supported topic, activity, lesson, decision, or task from the meaningful utterances as a whole. Prefer concrete subject matter over generic session labels.
Speaker fields are metadata added by NeoRecall, never words spoken by a participant. Transcription can also contain recognition artifacts that resemble speaker labels, counters, test markers, or descriptions of audio quality. Do not promote those artifacts, the recording setup, diarization, noise, silence, or transcription quality into the title or topic unless the people are clearly and intentionally discussing that exact subject.
When some speech is unclear, use the intelligible evidence and context to recover the best-supported subject. Do not diagnose the transcript in the title. Never invent a subject when no meaningful subject is supported.`

var outputLanguageDirective = map[string]string{
	"en": "English",
	"de": "German",
}

func AppendSystem(msgs []Message, content string) []Message {
	text := strings.TrimSpace(content)
	if text == "" {
		return msgs
	}
	firstOther := -1
	for i, m := range msgs {
		if m.Role != "system" {
			firstOther = i
			break
		}
	}
	sysCount := firstOther
	if sysCount == -1 {
		sysCount = len(msgs)
	}
	if sysCount == 0 {
		out := make([]Message, 0, len(msgs)+1)
		out = append(out, Message{Role: "system", Content: text})
		return append(out, msgs...)
	}
	var sysParts []string
	for i := 0; i < sysCount; i++ {
		if s, _ := msgs[i].Content.(string); strings.TrimSpace(s) != "" {
			sysParts = append(sysParts, strings.TrimSpace(s))
		}
	}
	sysParts = append(sysParts, text)
	out := make([]Message, 0, 1+len(msgs)-sysCount)
	out = append(out, Message{Role: "system", Content: strings.Join(sysParts, "\n\n")})
	return append(out, msgs[sysCount:]...)
}

func WithOutputLanguage(msgs []Message, lang *string) []Message {
	if lang == nil || *lang == "" {
		return msgs
	}
	name, ok := outputLanguageDirective[*lang]
	if !ok {
		return msgs
	}
	return AppendSystem(msgs, fmt.Sprintf("Output language: write all generated titles, summaries, topics, canonical entity names, action items, daily summaries and answers in %s, translating or summarizing non-%s transcripts cleanly while keeping proper names accurate.", name, name))
}

func WithInstructions(msgs []Message, settings UserSettingsSnapshot, area string) []Message {
	var parts []string
	if g := strings.TrimSpace(settings.InstructionsGlobal); g != "" {
		parts = append(parts, g)
	}
	var specific string
	switch area {
	case "memories":
		specific = settings.InstructionsMemories
	case "summaries":
		specific = settings.InstructionsSummaries
	case "ask":
		specific = settings.InstructionsAsk
	}
	if s := strings.TrimSpace(specific); s != "" {
		parts = append(parts, s)
	}
	if len(parts) == 0 {
		return msgs
	}
	intro := "The account owner has standing instructions for this kind of work. Follow them wherever they apply — tone, emphasis, level of detail, language, what matters to them and what does not. They never change the required output format, the schema, or the rule that you may only use the supplied material."
	return AppendSystem(msgs, intro+"\n\n"+strings.Join(parts, "\n\n"))
}

func localTimestamp(iso, timezone string) string {
	t, err := timeutil.ParseISO(iso)
	if err != nil {
		return iso
	}
	loc, err := time.LoadLocation(timezone)
	if err != nil {
		loc = time.UTC
	}
	lt := t.In(loc)
	_, offSec := lt.Zone()
	sign := "+"
	if offSec < 0 {
		sign = "-"
		offSec = -offSec
	}
	return fmt.Sprintf("%s%s%02d:%02d", lt.Format("2006-01-02T15:04:05"), sign, offSec/3600, (offSec%3600)/60)
}

type compactSegment struct {
	ID         string  `json:"id,omitempty"`
	OffsetMs   int64   `json:"offsetMs"`
	DurationMs int64   `json:"durationMs"`
	Speaker    *string `json:"speaker"`
	Language   *string `json:"language"`
	Text       string  `json:"text"`
}

type compactContextItem struct {
	ID            string  `json:"id"`
	Kind          string  `json:"kind"`
	OffsetMs      int64   `json:"offsetMs"`
	SourceName    *string `json:"sourceName"`
	Content       *string `json:"content"`
	AnalysisState string  `json:"analysisState"`
}

type compactConversation struct {
	ID       string `json:"id"`
	Stream   string `json:"stream"`
	Recorded struct {
		StartedAtUTC   string `json:"startedAtUtc"`
		EndedAtUTC     string `json:"endedAtUtc"`
		LocalStartedAt string `json:"localStartedAt"`
		LocalEndedAt   string `json:"localEndedAt"`
	} `json:"recorded"`
	Segments     []compactSegment     `json:"segments"`
	ContextItems []compactContextItem `json:"contextItems"`
}

type compactContinuationCandidate struct {
	ID                              string   `json:"id"`
	Type                            string   `json:"type"`
	TitleEn                         string   `json:"titleEn"`
	SummaryEn                       string   `json:"summaryEn"`
	StartedAt                       string   `json:"startedAt"`
	EndedAt                         string   `json:"endedAt"`
	MinutesBeforeThisInput          *int     `json:"minutesBeforeThisInput"`
	RecordedInSameStreamAsThisInput bool     `json:"recordedInSameStreamAsThisInput"`
	Speakers                        []string `json:"speakers"`
	Topics                          []string `json:"topics"`
	Highlights                      []string `json:"highlights"`
}

type compactRefs struct {
	CompactConversations          []compactConversation
	CompactContinuationCandidates []compactContinuationCandidate
	ReverseSegmentAliases         map[string]string
	ReverseMemoryAliases          map[string]string
	ReverseSpeakerAliases         map[string]string
}

func buildCompactInput(conversations []InputConversation, timezone string, candidates []ContinuationCandidate) compactRefs {
	refs := compactRefs{
		ReverseSegmentAliases: make(map[string]string),
		ReverseMemoryAliases:  make(map[string]string),
		ReverseSpeakerAliases: make(map[string]string),
	}
	speakerAliases := make(map[string]string)
	streamAliases := make(map[string]string)
	segOrd := 0

	speakerAlias := func(identity, clusterID string) string {
		if identity == "" {
			return ""
		}
		al, ok := speakerAliases[identity]
		if !ok {
			al = fmt.Sprintf("speaker%d", len(speakerAliases)+1)
			speakerAliases[identity] = al
		}
		if clusterID != "" && refs.ReverseSpeakerAliases[al] == "" {
			refs.ReverseSpeakerAliases[al] = clusterID
		}
		return al
	}

	var earliestStart string
	for ci, conv := range conversations {
		if earliestStart == "" || conv.StartedAt < earliestStart {
			earliestStart = conv.StartedAt
		}
		convStartT, _ := timeutil.ParseISO(conv.StartedAt)
		streamKey := conv.ID
		if conv.SessionID != nil && *conv.SessionID != "" {
			streamKey = *conv.SessionID
		}
		if _, ok := streamAliases[streamKey]; !ok {
			streamAliases[streamKey] = fmt.Sprintf("stream%d", len(streamAliases)+1)
		}
		var cc compactConversation
		cc.ID = fmt.Sprintf("c%d", ci+1)
		cc.Stream = streamAliases[streamKey]
		cc.Recorded.StartedAtUTC = conv.StartedAt
		cc.Recorded.EndedAtUTC = conv.EndedAt
		cc.Recorded.LocalStartedAt = localTimestamp(conv.StartedAt, timezone)
		cc.Recorded.LocalEndedAt = localTimestamp(conv.EndedAt, timezone)
		cc.Segments = make([]compactSegment, 0, len(conv.Segments))
		for _, seg := range conv.Segments {
			segOrd++
			al := fmt.Sprintf("s%d", segOrd)
			refs.ReverseSegmentAliases[al] = seg.ID
			stT, _ := timeutil.ParseISO(seg.StartedAt)
			enT, _ := timeutil.ParseISO(seg.EndedAt)
			var spkPtr *string
			if seg.SpeakerClusterID != nil && *seg.SpeakerClusterID != "" {
				ident := "cluster:" + *seg.SpeakerClusterID
				if seg.SpeakerVoiceprintID != nil && *seg.SpeakerVoiceprintID != "" {
					ident = "voiceprint:" + *seg.SpeakerVoiceprintID
				}
				sp := speakerAlias(ident, *seg.SpeakerClusterID)
				spkPtr = &sp
			}
			cc.Segments = append(cc.Segments, compactSegment{
				ID:         al,
				OffsetMs:   max(0, stT.Sub(convStartT).Milliseconds()),
				DurationMs: max(0, enT.Sub(stT).Milliseconds()),
				Speaker:    spkPtr,
				Language:   seg.Language,
				Text:       seg.Text,
			})
		}
		cc.ContextItems = make([]compactContextItem, 0, len(conv.ContextItems))
		for _, it := range conv.ContextItems {
			ctT, _ := timeutil.ParseISO(it.CapturedAt)
			cc.ContextItems = append(cc.ContextItems, compactContextItem{
				ID:            it.ID,
				Kind:          it.Kind,
				OffsetMs:      max(0, ctT.Sub(convStartT).Milliseconds()),
				SourceName:    it.SourceName,
				Content:       it.Content,
				AnalysisState: it.AnalysisState,
			})
		}
		refs.CompactConversations = append(refs.CompactConversations, cc)
	}

	earliestT, hasEarliest := timeutil.ParseISO(earliestStart)
	for mi, mem := range candidates {
		al := fmt.Sprintf("m%d", mi+1)
		refs.ReverseMemoryAliases[al] = mem.PublicID
		sameStream := false
		for _, sid := range mem.SessionIDs {
			if streamAliases[sid] != "" {
				sameStream = true
				break
			}
		}
		var spks []string
		for _, vid := range mem.SpeakerIdentities {
			if sp := speakerAlias("voiceprint:"+vid, ""); sp != "" {
				spks = append(spks, sp)
			}
		}
		if spks == nil {
			spks = []string{}
		}
		var minsPtr *int
		if hasEarliest == nil {
			if endT, err := timeutil.ParseISO(mem.EndedAt); err == nil {
				m := int((earliestT.Sub(endT).Milliseconds() + 30_000) / 60_000)
				minsPtr = &m
			}
		}
		topics := mem.Topics
		if topics == nil {
			topics = []string{}
		}
		hl := mem.Highlights
		if hl == nil {
			hl = []string{}
		}
		refs.CompactContinuationCandidates = append(refs.CompactContinuationCandidates, compactContinuationCandidate{
			ID:                              al,
			Type:                            mem.Type,
			TitleEn:                         mem.TitleEn,
			SummaryEn:                       mem.SummaryEn,
			StartedAt:                       localTimestamp(mem.StartedAt, timezone),
			EndedAt:                         localTimestamp(mem.EndedAt, timezone),
			MinutesBeforeThisInput:          minsPtr,
			RecordedInSameStreamAsThisInput: sameStream,
			Speakers:                        spks,
			Topics:                          topics,
			Highlights:                      hl,
		})
	}
	return refs
}

func jsonLen(v any) int {
	b, _ := json.Marshal(v)
	return len(b)
}

func windowConversations(convs []compactConversation, budgetChars int) [][]compactConversation {
	var windows [][]compactConversation
	var current []compactConversation
	size := 0
	flush := func() {
		if len(current) > 0 {
			windows = append(windows, current)
			current = nil
			size = 0
		}
	}
	for _, c := range convs {
		empty := c
		empty.Segments = []compactSegment{}
		env := jsonLen(empty)
		var batch []compactSegment
		batchSize := env
		pushBatch := func() {
			if len(batch) == 0 {
				return
			}
			part := c
			part.Segments = batch
			current = append(current, part)
			size += batchSize
			batch = nil
			batchSize = env
		}
		for _, seg := range c.Segments {
			sLen := jsonLen(seg)
			if len(batch) > 0 && size+batchSize+sLen > budgetChars {
				pushBatch()
				flush()
			}
			batch = append(batch, seg)
			batchSize += sLen
		}
		pushBatch()
		if size >= budgetChars {
			flush()
		}
	}
	flush()
	if len(windows) == 0 {
		return [][]compactConversation{{}}
	}
	return windows
}

type windowCarryOver struct {
	Section map[string]any `json:"section"`
	Memory  map[string]any `json:"memory"`
}

func buildCarryOver(merged *ConsolidationOutput) *windowCarryOver {
	if len(merged.ConversationSections) == 0 {
		return nil
	}
	sec := merged.ConversationSections[len(merged.ConversationSections)-1]
	secSet := make(map[string]bool, len(sec.SourceSegmentIDs))
	for _, id := range sec.SourceSegmentIDs {
		secSet[id] = true
	}
	var contMem map[string]any
	if len(merged.Memories) > 0 {
		lastMem := merged.Memories[len(merged.Memories)-1]
		shared := false
		for _, sid := range lastMem.SourceSegmentIDs {
			if secSet[sid] {
				shared = true
				break
			}
		}
		if shared {
			contMem = map[string]any{
				"type":               lastMem.Type,
				"titleEn":            lastMem.TitleEn,
				"summaryEn":          lastMem.SummaryEn,
				"emoji":              lastMem.Emoji,
				"importance":         lastMem.Importance,
				"topics":             lastMem.Topics,
				"continuesMemoryIds": lastMem.ContinuesMemoryIDs,
			}
		}
	}
	return &windowCarryOver{
		Section: map[string]any{
			"titleEn":      sec.TitleEn,
			"summaryEn":    sec.SummaryEn,
			"topics":       sec.Topics,
			"memoryWorthy": sec.MemoryWorthy,
		},
		Memory: contMem,
	}
}

const windowInstructions = `This request is one window of a transcript that was too long to read at once. The window before it has already been described, and its description is supplied as carryOver. The occasion it describes may still be running in this window.
Set continuesPrevious to true on your FIRST conversation section when this window opens in the middle of the occasion carryOver.section describes, and on the memory built from that section when it continues carryOver.memory. In that case write the title and summary of the WHOLE occasion — everything carryOver already says plus what this window adds — because NeoRecall replaces the earlier text with yours. Never refer to a previous window, never say the transcript is partial, and never repeat carryOver's segment IDs: cite only segment IDs from this window.
Set continuesPrevious to false on every other section and memory, including when this window opens a new occasion. Only the first section of the window may set it to true.
When a memory continues carryOver.memory, preserve its continuesMemoryIds. You may add another continuation candidate only if the wider evidence shows that candidate is another fragment of the exact same occasion.
`

func consolidationMessages(convs []compactConversation, candidates []compactContinuationCandidate, prevDaily *PreviousDailySummary, tz string, carry *windowCarryOver) []Message {
	sys := fmt.Sprintf(`You consolidate personal transcripts into reliable memories. Return one JSON object matching the supplied contract.
All titles, summaries, topics, canonical entity names, and mini-memory text MUST be in the output language, even when the source transcript is in another language. Preserve proper names accurately.
The input conversation objects are provisional local groups, not authoritative conversation boundaries. Produce conversationSections that partition the transcript into coherent real-world conversations or topic areas. You may merge adjacent input conversations when they belong to the same stream and same real conversation, and split any input conversation when its topic or real-world conversation changes. Never combine segments from different streams. A speaker change alone, a brief aside, or a short pause is not a topic boundary. Do not force a fixed number or duration of sections.
Every conversation section needs a concise specific title and a faithful standalone summary. Ordinary ambient speech can be marked not memory-worthy, but it still needs an accurate title and summary. Mini-memories are action items only and must be atomic and evidence-backed.
%s
User-supplied contextItems are evidence associated with the moment they were captured. Use ready notes and analyzed files to clarify names, facts and emphasis. A document may describe a plan or reference material rather than something said or completed; never misrepresent it as a spoken decision or finished event. A highlight marks the nearby transcript as important but adds no facts of its own.
memoryWorthy is a high bar. Set it true only for a substantial real-world occasion someone would open later as its own card — a meeting, lesson, multi-turn discussion, decision session, introduction with lasting context, or other experience with lasting narrative. Set it false for brief exchanges, hellos, logistics check-ins, one- or two-turn replies, ambient chatter, or any short stretch whose whole value is a single action item.
One real-world occasion is one memory. A single continuous meeting, lesson, lecture or call produces exactly one memory covering all of it, however long it ran and however many topics it moved through; use its internal topics and mini-memories to carry the detail instead of splitting it into several memories. Prefer zero memories over inventing thin ones. Choose the memory type that matches the occasion, and use %s exactly as named — lesson covers a class, lecture, seminar or any taught session.
continuationCandidates are memory cards NeoRecall already wrote, close enough in time or recording to be worth comparing with this input. For every output memory, first write continuationReasoning: one sentence naming what the new segments say about whether this is the same sitting as a candidate, or null when there are no candidates. Then set continuesMemoryIds accordingly. Use [] whenever the transcript does not show the earlier sitting still running.
Each memory needs exactly one emoji that a person would recognize as the occasion at a glance.
Create a mini-memory only for an actionable item that remains relevant after the conversation (task or promise, open status, dueAt UTC/localDateTime+timezone or null, occurredAt null).
When natural human speech identifies which speaker label a real person entity's voice belongs to, set that entity's speakerAlias to that speaker label; otherwise null.
Always return dailySummary as null.
Across conversationSections, include EVERY input segment ID exactly once, preserving order.
Use only segment IDs present in the input. Return no prose outside JSON.
Return at most %d memories, at most %d action items per memory, and at most %d entities.`,
		titleGuidance, strings.Join(MemoryTypes, "|"), MemoryMaxCount, MiniMemoryMaxCount, EntityMaxCount)
	if carry != nil {
		sys += "\n" + windowInstructions
	}

	var prevSum any
	if prevDaily != nil {
		prevSum = map[string]any{
			"localDate":         prevDaily.LocalDate,
			"timezone":          prevDaily.Timezone,
			"summaryEn":         prevDaily.SummaryEn,
			"coverageStartedAt": prevDaily.CoverageStartedAt,
			"coverageEndedAt":   prevDaily.CoverageEndedAt,
			"sourceCount":       prevDaily.SourceCount,
		}
	}
	userMap := map[string]any{
		"timezone":               tz,
		"previousDailySummary":   prevSum,
		"continuationCandidates": candidates,
		"conversations":          convs,
		"outputContract": map[string]any{
			"conversationSections": []map[string]any{{
				"titleEn": "Concise title", "summaryEn": "Faithful summary", "memoryWorthy": true,
				"continuesPrevious": false, "topics": []string{"topic"}, "sourceSegmentIds": []string{"s1"},
			}},
			"entities": []map[string]any{{
				"ref": "e1", "kind": strings.Join(EntityKinds, "|"), "canonicalNameEn": "Name",
				"displayName": nil, "aliases": []map[string]any{{"value": "alias", "language": nil}}, "speakerAlias": nil,
			}},
			"memories": []map[string]any{{
				"type": strings.Join(MemoryTypes, "|"), "continuesPrevious": false,
				"continuationReasoning": "one sentence or null", "continuesMemoryIds": []string{},
				"titleEn": "title", "summaryEn": "summary", "emoji": "🤝", "importance": 1,
				"sourceSegmentIds": []string{"s1"}, "topics": []string{"topic"},
				"entities": []map[string]any{{"ref": "e1", "role": "participant"}},
				"miniMemories": []map[string]any{{
					"kind": strings.Join(GeneratedMiniMemoryKinds, "|"), "textEn": "action", "importance": 1, "confidence": 0.5,
					"dueAt": nil, "occurredAt": nil, "status": "open", "sourceSegmentIds": []string{"s1"}, "entities": []any{},
				}},
			}},
			"dailySummary": nil,
		},
	}
	if carry != nil {
		userMap["carryOver"] = carry
	}
	ub, _ := json.Marshal(userMap)
	return []Message{
		{Role: "system", Content: sys},
		{Role: "user", Content: string(ub)},
	}
}

func planQueryMessages(question, nowLocal, timezone string) []Message {
	sys := strings.Join([]string{
		"You plan retrieval over a personal archive of transcripts, memories and daily summaries. You do not answer the question.",
		`Resolve every time expression in the question against the supplied current local time, and express the result as a half-open local range: fromLocal is inclusive, toLocal is exclusive, both "YYYY-MM-DDTHH:mm:ss" without an offset.`,
		"Set both to null when the question is not about a time at all.",
		"Set wholePeriod to true when the question asks what a period contained, and false when it asks about a subject that merely happens to sit in one.",
		"searchQueries: between one and three restatements of what to look for, in the language of the question, keeping names and other proper nouns exactly as written. Drop the time words from them — the range already carries the time. For a wholePeriod question a single short restatement is enough.",
		`Leave kinds empty. Retrieval already reads the written record first and the raw transcript second; set kinds only when the question explicitly asks for one layer — verbatim wording or who said what ("segment"), or the day's own summary ("daily_summary") — and understand that doing so hides everything else from the answer.`,
		"Return only the JSON object.",
	}, " ")
	ub, _ := json.Marshal(map[string]any{"question": question, "nowLocal": nowLocal, "timezone": timezone})
	return []Message{
		{Role: "system", Content: sys},
		{Role: "user", Content: string(ub)},
	}
}

func answerMessages(question string, contextItems []map[string]any, frame map[string]any) []Message {
	sys := strings.Join([]string{
		"Answer the user's question using only the supplied NeoRecall context.",
		"Answer in the output language, whatever language the question or the context is in.",
		`The context is that user's own recorded life. Items of kind "memory", "mini_memory" and "daily_summary" are the written record: already sorted, dated and titled, and they are what you answer from. Items of kind "segment" are raw transcript speech — reach for them for exact wording, for who said what, or when the written record does not cover the question, and never prefer them to a memory that says the same thing.`,
		"Each item carries the local time it happened, and nowLocal is the user's current local time — use them to place events relative to now and to order what you report.",
		"When the question asks what a period contained, report what the context actually holds for that period, most important first, and keep it to what a person would want read back to them.",
		`When the context holds nothing for what was asked, say that plainly. If an "archive" object is supplied it means retrieval found nothing for the period: say the period holds nothing recorded and, when latestActivityAt is given, say when the archive last holds something — do not state that nothing happened, because an empty period more often means it has not been written up yet. Never fill a gap with something that merely resembles the question, and never claim access to audio, the web, or anything outside the context.`,
		"Be specific and brief: no preamble, no restating the question.",
		`Cite evidence using only supplied source IDs. Return JSON with keys "answer" and "citations", where each citation is {"sourceId":"..."}.`,
	}, " ")
	uMap := map[string]any{"question": question, "context": contextItems}
	for k, v := range frame {
		uMap[k] = v
	}
	ub, _ := json.Marshal(uMap)
	return []Message{
		{Role: "system", Content: sys},
		{Role: "user", Content: string(ub)},
	}
}

func rewriteMemoryContextMessages(mem RewriteContextMemory, segs []RewriteContextSegment, items []RewriteContextItem) []Message {
	sys := strings.Join([]string{
		"You update an existing personal episodic memory after the user attached new files or notes.",
		titleGuidance,
		"Integrate factual details from analyzed files and user notes into the memory without inventing spoken claims or changing facts contradicted by the transcript.",
		"Keep topics concise, assign importance 1..10 and one emoji matching the occasion, extract actionable open miniMemories only when grounded in the evidence, and list every context item ID you drew from in sourceContextItemIds.",
		"Prefer the most specific memory type from: " + strings.Join(MemoryTypes, "|") + ". Return no prose outside JSON.",
	}, " ")
	var ctxPayload []map[string]any
	for _, item := range items {
		ctxPayload = append(ctxPayload, map[string]any{
			"id": item.ID, "kind": item.Kind, "capturedAt": item.CapturedAt,
			"content": item.Content, "sourceName": item.OriginalName,
		})
	}
	ub, _ := json.Marshal(map[string]any{
		"existingMemory": map[string]any{
			"type": mem.Type, "titleEn": mem.TitleEn, "summaryEn": mem.SummaryEn,
			"emoji": mem.Emoji, "importance": mem.Importance, "startedAt": mem.StartedAt, "endedAt": mem.EndedAt,
		},
		"transcriptSegments": segs,
		"contextItems":       ctxPayload,
		"outputContract": map[string]any{
			"type": strings.Join(MemoryTypes, "|"), "titleEn": "Concise title", "summaryEn": "Updated faithful summary",
			"emoji": "🤝", "importance": 5, "topics": []string{"topic"},
			"sourceContextItemIds": []string{},
			"miniMemories":         []any{},
		},
	})
	return []Message{
		{Role: "system", Content: sys},
		{Role: "user", Content: string(ub)},
	}
}
