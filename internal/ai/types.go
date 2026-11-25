package ai

import "github.com/NeoLabs-Systems/neorecall/internal/timeutil"

var (
	MemoryTypes              = []string{"meeting", "lesson", "conversation", "project_discussion", "introduction", "decision", "experience", "other"}
	MiniMemoryKinds          = []string{"fact", "event", "location", "person", "relationship", "task", "promise"}
	GeneratedMiniMemoryKinds = []string{"task", "promise"}
	EntityKinds              = []string{"person", "organization", "project", "location", "other"}

	DefaultMemoryEmoji = map[string]string{
		"meeting":            "🤝",
		"lesson":             "📚",
		"conversation":       "💬",
		"project_discussion": "📋",
		"introduction":       "👋",
		"decision":           "⚖️",
		"experience":         "✨",
		"other":              "💭",
	}

	TransientAICodes = map[string]bool{
		"AI_TIMEOUT":        true,
		"AI_HTTP_ERROR":     true,
		"AI_REQUEST_FAILED": true,
		"AI_EMPTY_RESPONSE": true,
		"AI_PROVIDER_ERROR": true,
	}
	ValidationFailureCodes = map[string]bool{
		"AI_REFERENCE_INVALID": true,
		"AI_SCHEMA_INVALID":    true,
		"AI_TEMPORAL_INVALID":  true,
		"AI_OUTPUT_TRUNCATED":  true,
		"AI_CONTEXT_EXCEEDED":  true,
	}
)

const (
	TitleMaxLength                 = 160
	SummaryMaxLength               = 2_000
	TopicMaxLength                 = 100
	TopicMaxCount                  = 12
	MemoryMaxCount                 = 3
	MiniMemoryMaxCount             = 8
	EntityMaxCount                 = 16
	EntityReferenceMaxCount        = 8
	ContinuationMemoryMaxCount     = 32
	ContinuationReasoningMaxLength = 400
	EmojiMaxLength                 = 16
)

func DefaultEmojiForType(t string) string {
	if e, ok := DefaultMemoryEmoji[t]; ok {
		return e
	}
	return DefaultMemoryEmoji["other"]
}

func BoundedText(s string, maxChars int) string {
	r := []rune(s)
	if len(r) <= maxChars {
		return s
	}
	return string(r[:maxChars-1]) + "…"
}

type Message struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

type ContentPart struct {
	Type      string `json:"type"`
	Text      string `json:"text,omitempty"`
	MediaType string `json:"mediaType,omitempty"`
	Data      string `json:"data,omitempty"`
}

type UserSettingsSnapshot struct {
	Language              *string
	InstructionsGlobal    string
	InstructionsMemories  string
	InstructionsSummaries string
	InstructionsAsk       string
}

type InputSegment struct {
	ID                  string
	StartedAt           string
	EndedAt             string
	Text                string
	Language            *string
	SpeakerClusterID    *string
	SpeakerVoiceprintID *string
}

type InputContextItem struct {
	ID            string
	Kind          string
	CapturedAt    string
	SourceName    *string
	Content       *string
	AnalysisState string
}

type InputConversation struct {
	ID           string
	SessionID    *string
	StartedAt    string
	EndedAt      string
	Segments     []InputSegment
	ContextItems []InputContextItem
}

type ContinuationCandidate struct {
	PublicID          string
	Type              string
	TitleEn           string
	SummaryEn         string
	StartedAt         string
	EndedAt           string
	Topics            []string
	Highlights        []string
	SessionIDs        []string
	SpeakerIdentities []string
}

type PreviousDailySummary struct {
	LocalDate         string
	Timezone          string
	SummaryEn         string
	CoverageStartedAt *string
	CoverageEndedAt   *string
	SourceCount       int
}

type ConsolidationInput struct {
	Conversations          []InputConversation
	PreviousDailySummary   *PreviousDailySummary
	Timezone               string
	ContinuationCandidates []ContinuationCandidate
}

type ConversationSection struct {
	TitleEn           string   `json:"titleEn"`
	SummaryEn         string   `json:"summaryEn"`
	MemoryWorthy      bool     `json:"memoryWorthy"`
	ContinuesPrevious bool     `json:"continuesPrevious"`
	Topics            []string `json:"topics"`
	SourceSegmentIDs  []string `json:"sourceSegmentIds"`
}

type EntityAlias struct {
	Value    string  `json:"value"`
	Language *string `json:"language"`
}

type ConsolidationEntity struct {
	Ref             string        `json:"ref"`
	Kind            string        `json:"kind"`
	CanonicalNameEn string        `json:"canonicalNameEn"`
	DisplayName     *string       `json:"displayName"`
	Aliases         []EntityAlias `json:"aliases"`
	SpeakerAlias    *string       `json:"speakerAlias"`
}

type EntityReference struct {
	Ref  string `json:"ref"`
	Role string `json:"role"`
}

type ConsolidationMiniMemory struct {
	Kind             string            `json:"kind"`
	TextEn           string            `json:"textEn"`
	Importance       float64           `json:"importance"`
	Confidence       float64           `json:"confidence"`
	DueAt            any               `json:"dueAt"`
	DueAtISO         *string           `json:"-"`
	OccurredAt       any               `json:"occurredAt"`
	Status           *string           `json:"status"`
	SourceSegmentIDs []string          `json:"sourceSegmentIds"`
	Entities         []EntityReference `json:"entities"`
}

type ConsolidationMemory struct {
	Type                  string                    `json:"type"`
	ContinuesPrevious     bool                      `json:"continuesPrevious"`
	ContinuationReasoning *string                   `json:"continuationReasoning"`
	ContinuesMemoryIDs    []string                  `json:"continuesMemoryIds"`
	TitleEn               string                    `json:"titleEn"`
	SummaryEn             string                    `json:"summaryEn"`
	Emoji                 string                    `json:"emoji"`
	Importance            float64                   `json:"importance"`
	SourceSegmentIDs      []string                  `json:"sourceSegmentIds"`
	Topics                []string                  `json:"topics"`
	Entities              []EntityReference         `json:"entities"`
	MiniMemories          []ConsolidationMiniMemory `json:"miniMemories"`
}

type DailySummaryOutput struct {
	SummaryEn string `json:"summaryEn"`
}

type ConsolidationOutput struct {
	ConversationSections []ConversationSection `json:"conversationSections"`
	Entities             []ConsolidationEntity `json:"entities"`
	Memories             []ConsolidationMemory `json:"memories"`
	DailySummary         *DailySummaryOutput   `json:"dailySummary"`
}

type ConsolidationResult struct {
	Value           ConsolidationOutput
	RequestID       string
	Windows         int
	SpeakerClusters map[string]string // speakerAlias -> speakerClusterID
}

type PreviewOutput struct {
	TitleEn      string   `json:"titleEn"`
	SummaryEn    string   `json:"summaryEn"`
	MemoryWorthy bool     `json:"memoryWorthy"`
	Topics       []string `json:"topics"`
}

type RewriteContextMemory struct {
	Type       string
	TitleEn    string
	SummaryEn  string
	Emoji      string
	Importance float64
	StartedAt  string
	EndedAt    string
}

type RewriteContextSegment struct {
	PublicID  string `json:"id"`
	StartedAt string `json:"startedAt"`
	EndedAt   string `json:"endedAt"`
	Text      string `json:"text"`
}

type RewriteContextItem struct {
	ID           string  `json:"id"`
	Kind         string  `json:"kind"`
	CapturedAt   string  `json:"capturedAt"`
	NoteText     string  `json:"-"`
	AnalysisText string  `json:"-"`
	Content      string  `json:"content"`
	OriginalName *string `json:"sourceName"`
}

type MemoryMergeInput struct {
	Type         string
	TitleEn      string
	SummaryEn    string
	Emoji        string
	StartedAt    string
	EndedAt      string
	Topics       []string
	MiniMemories []struct {
		Kind   string  `json:"kind"`
		TextEn string  `json:"textEn"`
		Status *string `json:"status"`
	}
}

type MemoryMergeOutput struct {
	Type      string `json:"type"`
	TitleEn   string `json:"titleEn"`
	SummaryEn string `json:"summaryEn"`
	Emoji     string `json:"emoji"`
}

type MemoryDedupeOutput struct {
	Reasoning    string `json:"reasoning"`
	SameOccasion bool   `json:"sameOccasion"`
}

type AIError struct {
	Code      string
	Status    int
	RequestID string
	Message   string
}

func (e *AIError) Error() string { return e.Message }

func normalizeTemporalRef(v any) (*string, error) {
	if v == nil {
		return nil, nil
	}
	switch x := v.(type) {
	case string:
		if x == "" {
			return nil, nil
		}
		t, err := timeutil.ParseISO(x)
		if err != nil {
			return nil, err
		}
		iso := timeutil.FormatISO(t)
		return &iso, nil
	case map[string]any:
		ldt, _ := x["localDateTime"].(string)
		tz, _ := x["timezone"].(string)
		if ldt == "" || tz == "" {
			return nil, &AIError{Code: "AI_TEMPORAL_INVALID", Message: "incomplete temporal reference object"}
		}
		iso, err := timeutil.LocalDateTimeToUTC(ldt, tz)
		if err != nil {
			return nil, err
		}
		return &iso, nil
	default:
		return nil, &AIError{Code: "AI_TEMPORAL_INVALID", Message: "unsupported temporal reference"}
	}
}
