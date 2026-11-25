package ai

import (
	"fmt"
	"slices"
	"strings"
)

func ConsolidationJsonSchemaFor(segmentIDs, continuationMemoryIDs []string) map[string]any {
	nullableStr := map[string]any{"anyOf": []any{map[string]any{"type": "string"}, map[string]any{"type": "null"}}}
	sourceIDsSchema := map[string]any{
		"type":     "array",
		"minItems": 1,
		"items":    map[string]any{"type": "string", "minLength": 1, "enum": segmentIDs},
	}
	topicsSchema := map[string]any{
		"type":     "array",
		"maxItems": TopicMaxCount,
		"items":    map[string]any{"type": "string", "minLength": 1, "maxLength": TopicMaxLength},
	}
	importanceSchema := map[string]any{"type": "number", "enum": []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}}
	entityRefsSchema := map[string]any{
		"type":     "array",
		"maxItems": EntityReferenceMaxCount,
		"items": map[string]any{
			"type":                 "object",
			"additionalProperties": false,
			"required":             []string{"ref", "role"},
			"properties": map[string]any{
				"ref":  map[string]any{"type": "string", "minLength": 1},
				"role": map[string]any{"type": "string", "minLength": 1},
			},
		},
	}
	temporalSchema := map[string]any{
		"anyOf": []any{
			map[string]any{"type": "null"},
			map[string]any{
				"type":                 "object",
				"additionalProperties": false,
				"required":             []string{"localDateTime", "timezone"},
				"properties": map[string]any{
					"localDateTime": map[string]any{"type": "string", "pattern": `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$`},
					"timezone":      map[string]any{"type": "string", "minLength": 1},
				},
			},
		},
	}

	var contReasoningSchema any = map[string]any{"type": "null"}
	contMemProps := map[string]any{"type": "string", "minLength": 1}
	contMemMax := 0
	if len(continuationMemoryIDs) > 0 {
		contReasoningSchema = map[string]any{"type": "string", "minLength": 1, "maxLength": ContinuationReasoningMaxLength}
		contMemProps["enum"] = continuationMemoryIDs
		contMemMax = min(ContinuationMemoryMaxCount, len(continuationMemoryIDs))
	}

	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"conversationSections", "entities", "memories", "dailySummary"},
		"properties": map[string]any{
			"conversationSections": map[string]any{
				"type":     "array",
				"minItems": 1,
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required":             []string{"titleEn", "summaryEn", "memoryWorthy", "topics", "continuesPrevious", "sourceSegmentIds"},
					"properties": map[string]any{
						"titleEn":           map[string]any{"type": "string", "minLength": 1, "maxLength": TitleMaxLength},
						"summaryEn":         map[string]any{"type": "string", "minLength": 1, "maxLength": SummaryMaxLength},
						"memoryWorthy":      map[string]any{"type": "boolean"},
						"topics":            topicsSchema,
						"continuesPrevious": map[string]any{"type": "boolean"},
						"sourceSegmentIds":  sourceIDsSchema,
					},
				},
			},
			"entities": map[string]any{
				"type":     "array",
				"maxItems": EntityMaxCount,
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required":             []string{"ref", "kind", "canonicalNameEn", "displayName", "aliases", "speakerAlias"},
					"properties": map[string]any{
						"ref":             map[string]any{"type": "string", "minLength": 1},
						"kind":            map[string]any{"type": "string", "enum": EntityKinds},
						"canonicalNameEn": map[string]any{"type": "string", "minLength": 1},
						"displayName":     nullableStr,
						"aliases": map[string]any{
							"type":     "array",
							"maxItems": EntityReferenceMaxCount,
							"items": map[string]any{
								"type":                 "object",
								"additionalProperties": false,
								"required":             []string{"value", "language"},
								"properties": map[string]any{
									"value":    map[string]any{"type": "string", "minLength": 1},
									"language": nullableStr,
								},
							},
						},
						"speakerAlias": nullableStr,
					},
				},
			},
			"memories": map[string]any{
				"type":     "array",
				"maxItems": MemoryMaxCount,
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required": []string{
						"type", "continuesPrevious", "continuationReasoning", "continuesMemoryIds",
						"titleEn", "summaryEn", "emoji", "importance", "sourceSegmentIds", "topics", "entities", "miniMemories",
					},
					"properties": map[string]any{
						"type":                  map[string]any{"type": "string", "enum": MemoryTypes},
						"continuesPrevious":     map[string]any{"type": "boolean"},
						"continuationReasoning": contReasoningSchema,
						"continuesMemoryIds": map[string]any{
							"type":     "array",
							"maxItems": contMemMax,
							"items":    contMemProps,
						},
						"titleEn":          map[string]any{"type": "string", "minLength": 1, "maxLength": TitleMaxLength},
						"summaryEn":        map[string]any{"type": "string", "minLength": 1, "maxLength": SummaryMaxLength},
						"emoji":            map[string]any{"type": "string", "minLength": 1, "maxLength": EmojiMaxLength},
						"importance":       importanceSchema,
						"sourceSegmentIds": sourceIDsSchema,
						"topics":           topicsSchema,
						"entities":         entityRefsSchema,
						"miniMemories": map[string]any{
							"type":     "array",
							"maxItems": MiniMemoryMaxCount,
							"items": map[string]any{
								"type":                 "object",
								"additionalProperties": false,
								"required":             []string{"kind", "textEn", "importance", "confidence", "dueAt", "occurredAt", "status", "sourceSegmentIds", "entities"},
								"properties": map[string]any{
									"kind":             map[string]any{"type": "string", "enum": GeneratedMiniMemoryKinds},
									"textEn":           map[string]any{"type": "string", "minLength": 1},
									"importance":       importanceSchema,
									"confidence":       map[string]any{"type": "number", "minimum": 0, "maximum": 1},
									"dueAt":            temporalSchema,
									"occurredAt":       map[string]any{"type": "null"},
									"status":           map[string]any{"type": "string", "enum": []string{"open"}},
									"sourceSegmentIds": sourceIDsSchema,
									"entities":         entityRefsSchema,
								},
							},
						},
					},
				},
			},
			"dailySummary": map[string]any{"anyOf": []any{map[string]any{"type": "null"}, DailySummaryJsonSchema}},
		},
	}
}

var (
	QueryPlanJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"searchQueries", "fromLocal", "toLocal", "kinds", "wholePeriod"},
		"properties": map[string]any{
			"searchQueries": map[string]any{"type": "array", "minItems": 1, "maxItems": 8, "items": map[string]any{"type": "string"}},
			"fromLocal":     map[string]any{"type": []string{"string", "null"}},
			"toLocal":       map[string]any{"type": []string{"string", "null"}},
			"kinds":         map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": []string{"segment", "memory", "mini_memory", "daily_summary"}}},
			"wholePeriod":   map[string]any{"type": "boolean"},
		},
	}
	AnswerJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"answer", "citations"},
		"properties": map[string]any{
			"answer": map[string]any{"type": "string", "minLength": 1},
			"citations": map[string]any{
				"type": "array",
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required":             []string{"sourceId"},
					"properties":           map[string]any{"sourceId": map[string]any{"type": "string", "minLength": 1}},
				},
			},
		},
	}
	DailySummaryJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"summaryEn"},
		"properties":           map[string]any{"summaryEn": map[string]any{"type": "string", "minLength": 1}},
	}
	ConversationPreviewJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"titleEn", "summaryEn", "memoryWorthy", "topics"},
		"properties": map[string]any{
			"titleEn":      map[string]any{"type": "string", "minLength": 1, "maxLength": TitleMaxLength},
			"summaryEn":    map[string]any{"type": "string", "minLength": 1, "maxLength": SummaryMaxLength},
			"memoryWorthy": map[string]any{"type": "boolean"},
			"topics":       map[string]any{"type": "array", "maxItems": TopicMaxCount, "items": map[string]any{"type": "string", "minLength": 1, "maxLength": TopicMaxLength}},
		},
	}
	ContextAnalysisJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"descriptionEn"},
		"properties":           map[string]any{"descriptionEn": map[string]any{"type": "string", "minLength": 1}},
	}
	MemoryMergeJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"type", "titleEn", "summaryEn", "emoji"},
		"properties": map[string]any{
			"type":      map[string]any{"type": "string", "enum": MemoryTypes},
			"titleEn":   map[string]any{"type": "string", "minLength": 1, "maxLength": TitleMaxLength},
			"summaryEn": map[string]any{"type": "string", "minLength": 1, "maxLength": SummaryMaxLength},
			"emoji":     map[string]any{"type": "string", "minLength": 1, "maxLength": EmojiMaxLength},
		},
	}
	MemoryDedupeJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"reasoning", "sameOccasion"},
		"properties": map[string]any{
			"reasoning":    map[string]any{"type": "string", "minLength": 1, "maxLength": 400},
			"sameOccasion": map[string]any{"type": "boolean"},
		},
	}
	MemoryContextRewriteJsonSchema = map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"type", "titleEn", "summaryEn", "emoji", "importance", "topics", "sourceContextItemIds", "miniMemories"},
		"properties": map[string]any{
			"type":                 map[string]any{"type": "string", "enum": MemoryTypes},
			"titleEn":              map[string]any{"type": "string", "minLength": 1},
			"summaryEn":            map[string]any{"type": "string", "minLength": 1},
			"emoji":                map[string]any{"type": "string", "minLength": 1},
			"importance":           map[string]any{"type": "number", "minimum": 1, "maximum": 10},
			"topics":               map[string]any{"type": "array", "maxItems": 24, "items": map[string]any{"type": "string", "minLength": 1}},
			"sourceContextItemIds": map[string]any{"type": "array", "items": map[string]any{"type": "string", "format": "uuid"}},
			"miniMemories": map[string]any{
				"type":     "array",
				"maxItems": 8,
				"items": map[string]any{
					"type":                 "object",
					"additionalProperties": false,
					"required":             []string{"kind", "textEn", "importance", "confidence", "dueAt", "status", "sourceSegmentIds"},
					"properties": map[string]any{
						"kind":             map[string]any{"type": "string", "enum": GeneratedMiniMemoryKinds},
						"textEn":           map[string]any{"type": "string", "minLength": 1},
						"importance":       map[string]any{"type": "number", "minimum": 1, "maximum": 10},
						"confidence":       map[string]any{"type": "number", "minimum": 0, "maximum": 1},
						"dueAt":            map[string]any{"type": []string{"string", "null"}, "format": "date-time"},
						"status":           map[string]any{"type": "string", "enum": []string{"open"}},
						"sourceSegmentIds": map[string]any{"type": "array", "items": map[string]any{"type": "string", "format": "uuid"}},
					},
				},
			},
		},
	}
)

func ValidateAndNormalizeConsolidation(out *ConsolidationOutput) error {
	if len(out.ConversationSections) == 0 {
		return fmt.Errorf("conversationSections must contain at least 1 section")
	}
	for i := range out.ConversationSections {
		sec := &out.ConversationSections[i]
		if strings.TrimSpace(sec.TitleEn) == "" || strings.TrimSpace(sec.SummaryEn) == "" || len(sec.SourceSegmentIDs) == 0 {
			return fmt.Errorf("conversationSections[%d] invalid", i)
		}
		sec.TitleEn = BoundedText(sec.TitleEn, TitleMaxLength)
		sec.SummaryEn = BoundedText(sec.SummaryEn, SummaryMaxLength)
		if len(sec.Topics) > TopicMaxCount {
			sec.Topics = sec.Topics[:TopicMaxCount]
		}
		for j := range sec.Topics {
			sec.Topics[j] = BoundedText(sec.Topics[j], TopicMaxLength)
		}
	}
	for i := range out.Entities {
		ent := &out.Entities[i]
		if ent.Ref == "" || ent.CanonicalNameEn == "" || !slices.Contains(EntityKinds, ent.Kind) {
			return fmt.Errorf("entities[%d] invalid", i)
		}
	}
	for i := range out.Memories {
		mem := &out.Memories[i]
		if !slices.Contains(MemoryTypes, mem.Type) || strings.TrimSpace(mem.TitleEn) == "" || strings.TrimSpace(mem.SummaryEn) == "" || len(mem.SourceSegmentIDs) == 0 {
			return fmt.Errorf("memories[%d] invalid", i)
		}
		if mem.Importance < 1 || mem.Importance > 10 {
			return fmt.Errorf("memories[%d].importance out of bounds", i)
		}
		mem.TitleEn = BoundedText(mem.TitleEn, TitleMaxLength)
		mem.SummaryEn = BoundedText(mem.SummaryEn, SummaryMaxLength)
		if mem.ContinuationReasoning != nil {
			b := BoundedText(*mem.ContinuationReasoning, ContinuationReasoningMaxLength)
			mem.ContinuationReasoning = &b
		}
		mem.Emoji = strings.TrimSpace(mem.Emoji)
		if mem.Emoji == "" {
			mem.Emoji = DefaultEmojiForType(mem.Type)
		}
		if len([]rune(mem.Emoji)) > EmojiMaxLength {
			mem.Emoji = string([]rune(mem.Emoji)[:EmojiMaxLength])
		}
		if len(mem.Topics) > TopicMaxCount {
			mem.Topics = mem.Topics[:TopicMaxCount]
		}
		for j := range mem.Topics {
			mem.Topics[j] = BoundedText(mem.Topics[j], TopicMaxLength)
		}
		var kept []ConsolidationMiniMemory
		for _, mini := range mem.MiniMemories {
			if !slices.Contains(GeneratedMiniMemoryKinds, mini.Kind) {
				continue
			}
			if mini.Status != nil && (*mini.Status == "completed" || *mini.Status == "cancelled") {
				continue
			}
			if strings.TrimSpace(mini.TextEn) == "" || len(mini.SourceSegmentIDs) == 0 {
				return fmt.Errorf("memories[%d].miniMemories invalid", i)
			}
			iso, err := normalizeTemporalRef(mini.DueAt)
			if err != nil {
				return &AIError{Code: "AI_TEMPORAL_INVALID", Message: err.Error()}
			}
			mini.DueAtISO = iso
			mini.OccurredAt = nil
			openSt := "open"
			mini.Status = &openSt
			kept = append(kept, mini)
		}
		mem.MiniMemories = kept
	}
	return nil
}
