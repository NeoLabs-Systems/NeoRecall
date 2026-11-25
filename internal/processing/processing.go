package processing

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

// Settings holds runtime-adjustable processing thresholds overlaid on env config.
type Settings struct {
	VoiceMatchThreshold                  float64 `json:"voiceMatchThreshold"`
	VoiceMatchMargin                     float64 `json:"voiceMatchMargin"`
	VoiceEnrollFloor                     float64 `json:"voiceEnrollFloor"`
	VoiceEnrollMinimumMs                 int     `json:"voiceEnrollMinimumMs"`
	VoiceRepairThreshold                 float64 `json:"voiceRepairThreshold"`
	SpeakerClusterThreshold              float64 `json:"speakerClusterThreshold"`
	SpeakerClusterMergeThreshold         float64 `json:"speakerClusterMergeThreshold"`
	SpeakerMinimumTurnMs                 int     `json:"speakerMinimumTurnMs"`
	DiarizationClusterDistance           float64 `json:"diarizationClusterDistance"`
	SpeakerClusterMargin                 float64 `json:"speakerClusterMargin"`
	SpeakerContinuityGapMs               int     `json:"speakerContinuityGapMs"`
	SpeakerClusterContinuityThreshold    float64 `json:"speakerClusterContinuityThreshold"`
	AudioPreprocessEnabled               bool    `json:"audioPreprocessEnabled"`
	AudioPreprocessHighpassHz            int     `json:"audioPreprocessHighpassHz"`
	AudioPreprocessDenoiseDb             float64 `json:"audioPreprocessDenoiseDb"`
	AudioPreprocessMaxGain               float64 `json:"audioPreprocessMaxGain"`
	DedupeTokenSimilarity                float64 `json:"dedupeTokenSimilarity"`
	DedupeTimeToleranceMs                int     `json:"dedupeTimeToleranceMs"`
	TranscriptRepetitionMinimumRepeats   int     `json:"transcriptRepetitionMinimumRepeats"`
	TranscriptRepetitionMaxPatternWords  int     `json:"transcriptRepetitionMaximumPatternWords"`
	TranscriptRepetitionMinimumCoverage  float64 `json:"transcriptRepetitionMinimumCoverage"`
	TranscriptMaximumWordsPerSecond      float64 `json:"transcriptMaximumWordsPerSecond"`
	ConversationHardGapMs                int64   `json:"conversationHardGapMs"`
	ConversationSoftGapMs                int64   `json:"conversationSoftGapMs"`
	ConversationMinimumMs                int64   `json:"conversationMinimumMs"`
	ConversationQuietCloseMs             int64   `json:"conversationQuietCloseMs"`
	ConversationValleyQuantile           float64 `json:"conversationValleyQuantile"`
	ConversationSemanticSimilarityThr    float64 `json:"conversationSemanticSimilarityThreshold"`
	ConversationSemanticValleyProminence float64 `json:"conversationSemanticValleyProminence"`
	ConversationSemanticContextSegments  int     `json:"conversationSemanticContextSegments"`
	ConversationMaximumMs                int64   `json:"conversationMaximumMs"`
	ConversationMaximumCharacters        int     `json:"conversationMaximumCharacters"`
	ConversationPreviewMinCharacters     int     `json:"conversationPreviewMinCharacters"`
	ConversationPreviewRefreshChars      int     `json:"conversationPreviewRefreshCharacters"`
	ConversationPreviewMinIntervalMs     int64   `json:"conversationPreviewMinIntervalMs"`
	ConversationPreviewFullCharacters    int     `json:"conversationPreviewFullCharacters"`
	MinAIAudioMs                         int64   `json:"minAiAudioMs"`
	MinNewMaterialChars                  int     `json:"minNewMaterialChars"`
	MinMemoryEvidenceMs                  int64   `json:"minMemoryEvidenceMs"`
	MinMemoryEvidenceChars               int     `json:"minMemoryEvidenceChars"`
	MaxConsolidationInputChars           int     `json:"maxConsolidationInputChars"`
	MaxConsolidationConversations        int     `json:"maxConsolidationConversations"`
	MaxMemoryContinuationCandidates      int     `json:"maxMemoryContinuationCandidates"`
	MemoryContinuationLookbackMs         int64   `json:"memoryContinuationLookbackMs"`
	MaxConsolidationLatencyMs            int64   `json:"maxConsolidationLatencyMs"`
	MemoryOccasionGapMs                  int64   `json:"memoryOccasionGapMs"`
	MemorySettleMs                       int64   `json:"memorySettleMs"`
	MemoryOccasionMaxWaitMs              int64   `json:"memoryOccasionMaxWaitMs"`
	MemoryDedupeEnabled                  bool    `json:"memoryDedupeEnabled"`
	MemoryDedupeSimilarityThreshold      float64 `json:"memoryDedupeSimilarityThreshold"`
	MemoryDedupeWindowMs                 int64   `json:"memoryDedupeWindowMs"`
	MemoryDedupeMaxPairsPerRun           int     `json:"memoryDedupeMaxPairsPerRun"`
	MemoryDedupeNeighbours               int     `json:"memoryDedupeNeighbours"`
	ConsolidationMaxFailures             int     `json:"consolidationMaxFailures"`
}

func fromConfig(c config.Config) Settings {
	return Settings{
		VoiceMatchThreshold:                  c.VoiceMatchThreshold,
		VoiceMatchMargin:                     c.VoiceMatchMargin,
		VoiceEnrollFloor:                     c.VoiceEnrollFloor,
		VoiceEnrollMinimumMs:                 c.VoiceEnrollMinimumMs,
		VoiceRepairThreshold:                 c.VoiceRepairThreshold,
		SpeakerClusterThreshold:              c.SpeakerClusterThreshold,
		SpeakerClusterMergeThreshold:         c.SpeakerClusterMergeThreshold,
		SpeakerMinimumTurnMs:                 c.SpeakerMinimumTurnMs,
		DiarizationClusterDistance:           c.DiarizationClusterDistance,
		SpeakerClusterMargin:                 c.SpeakerClusterMargin,
		SpeakerContinuityGapMs:               c.SpeakerContinuityGapMs,
		SpeakerClusterContinuityThreshold:    c.SpeakerClusterContinuityThr,
		AudioPreprocessEnabled:               c.AudioPreprocessEnabled,
		AudioPreprocessHighpassHz:            c.AudioPreprocessHighpassHz,
		AudioPreprocessDenoiseDb:             c.AudioPreprocessDenoiseDb,
		AudioPreprocessMaxGain:               c.AudioPreprocessMaxGain,
		DedupeTokenSimilarity:                c.DedupeTokenSimilarity,
		DedupeTimeToleranceMs:                c.DedupeTimeToleranceMs,
		TranscriptRepetitionMinimumRepeats:   c.TranscriptRepetitionMinimumRepeats,
		TranscriptRepetitionMaxPatternWords:  c.TranscriptRepetitionMaxPatternWords,
		TranscriptRepetitionMinimumCoverage:  c.TranscriptRepetitionMinimumCoverage,
		TranscriptMaximumWordsPerSecond:      c.TranscriptMaximumWordsPerSecond,
		ConversationHardGapMs:                c.ConversationHardGapMs,
		ConversationSoftGapMs:                c.ConversationSoftGapMs,
		ConversationMinimumMs:                c.ConversationMinimumMs,
		ConversationQuietCloseMs:             c.ConversationQuietCloseMs,
		ConversationValleyQuantile:           c.ConversationValleyQuantile,
		ConversationSemanticSimilarityThr:    c.ConversationSemanticSimilarityThr,
		ConversationSemanticValleyProminence: c.ConversationSemanticValleyProminence,
		ConversationSemanticContextSegments:  c.ConversationSemanticContextSegments,
		ConversationMaximumMs:                c.ConversationMaximumMs,
		ConversationMaximumCharacters:        c.ConversationMaximumCharacters,
		ConversationPreviewMinCharacters:     c.ConversationPreviewMinCharacters,
		ConversationPreviewRefreshChars:      c.ConversationPreviewRefreshChars,
		ConversationPreviewMinIntervalMs:     c.ConversationPreviewMinIntervalMs,
		ConversationPreviewFullCharacters:    c.ConversationPreviewFullCharacters,
		MinAIAudioMs:                         c.MinAIAudioMs,
		MinNewMaterialChars:                  c.MinNewMaterialChars,
		MinMemoryEvidenceMs:                  c.MinMemoryEvidenceMs,
		MinMemoryEvidenceChars:               c.MinMemoryEvidenceChars,
		MaxConsolidationInputChars:           c.MaxConsolidationInputChars,
		MaxConsolidationConversations:        c.MaxConsolidationConvs,
		MaxMemoryContinuationCandidates:      c.MaxMemoryContinuationCands,
		MemoryContinuationLookbackMs:         c.MemoryContinuationLookbackMs,
		MaxConsolidationLatencyMs:            c.MaxConsolidationLatencyMs,
		MemoryOccasionGapMs:                  c.MemoryOccasionGapMs,
		MemorySettleMs:                       c.MemorySettleMs,
		MemoryOccasionMaxWaitMs:              c.MemoryOccasionMaxWaitMs,
		MemoryDedupeEnabled:                  c.MemoryDedupeEnabled,
		MemoryDedupeSimilarityThreshold:      c.MemoryDedupeSimilarityThr,
		MemoryDedupeWindowMs:                 c.MemoryDedupeWindowMs,
		MemoryDedupeMaxPairsPerRun:           c.MemoryDedupeMaxPairsPerRun,
		MemoryDedupeNeighbours:               c.MemoryDedupeNeighbours,
		ConsolidationMaxFailures:             c.ConsolidationMaxFailures,
	}
}

type Service struct {
	DB  *dbx.DB
	Cfg func() config.Config
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) Get(ctx context.Context) Settings {
	st := fromConfig(s.cfg())
	if s.DB == nil {
		return st
	}
	// Overlay persisted app_settings JSON values matching the Settings struct.
	rawMap := map[string]any{}
	b, _ := json.Marshal(st)
	_ = json.Unmarshal(b, &rawMap)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT key, value_json FROM app_settings`)
	if err != nil {
		return st
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		if rows.Scan(&k, &v) != nil {
			continue
		}
		if _, known := rawMap[k]; !known {
			continue
		}
		var parsed any
		if json.Unmarshal([]byte(v), &parsed) == nil {
			rawMap[k] = parsed
		}
	}
	merged, err := json.Marshal(rawMap)
	if err == nil {
		_ = json.Unmarshal(merged, &st)
	}
	return st
}

func Validate(st Settings) error {
	checkF := func(v, lo, hi float64, msg string) error {
		if v < lo || v > hi {
			return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", msg)
		}
		return nil
	}
	checkI := func(v, lo, hi int64, msg string) error {
		if v < lo || v > hi {
			return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", msg)
		}
		return nil
	}
	checks := []error{
		checkF(st.VoiceMatchThreshold, -1, 1, "voiceMatchThreshold out of range"),
		checkF(st.VoiceMatchMargin, 0, 2, "voiceMatchMargin out of range"),
		checkF(st.VoiceEnrollFloor, -1, 1, "voiceEnrollFloor out of range"),
		checkI(int64(st.VoiceEnrollMinimumMs), 0, 120_000, "voiceEnrollMinimumMs out of range"),
		checkF(st.VoiceRepairThreshold, -1, 1, "voiceRepairThreshold out of range"),
		checkF(st.SpeakerClusterThreshold, -1, 1, "speakerClusterThreshold out of range"),
		checkF(st.SpeakerClusterMergeThreshold, -1, 1, "speakerClusterMergeThreshold out of range"),
		checkI(int64(st.SpeakerMinimumTurnMs), 0, 60_000, "speakerMinimumTurnMs out of range"),
		checkF(st.DiarizationClusterDistance, 0, 2, "diarizationClusterDistance out of range"),
		checkF(st.SpeakerClusterMargin, 0, 2, "speakerClusterMargin out of range"),
		checkI(int64(st.SpeakerContinuityGapMs), 0, 60_000, "speakerContinuityGapMs out of range"),
		checkF(st.SpeakerClusterContinuityThreshold, -1, 1, "speakerClusterContinuityThreshold out of range"),
		checkI(int64(st.AudioPreprocessHighpassHz), 0, 300, "audioPreprocessHighpassHz out of range"),
		checkF(st.AudioPreprocessDenoiseDb, 0.01, 97, "audioPreprocessDenoiseDb out of range"),
		checkF(st.AudioPreprocessMaxGain, 1, 100, "audioPreprocessMaxGain out of range"),
		checkF(st.DedupeTokenSimilarity, 0, 1, "dedupeTokenSimilarity out of range"),
		checkI(int64(st.DedupeTimeToleranceMs), 0, 30_000, "dedupeTimeToleranceMs out of range"),
		checkI(int64(st.TranscriptRepetitionMinimumRepeats), 3, 1_000, "transcriptRepetitionMinimumRepeats out of range"),
		checkI(int64(st.TranscriptRepetitionMaxPatternWords), 1, 32, "transcriptRepetitionMaximumPatternWords out of range"),
		checkF(st.TranscriptRepetitionMinimumCoverage, 0.5, 1, "transcriptRepetitionMinimumCoverage out of range"),
		checkF(st.TranscriptMaximumWordsPerSecond, 1, 50, "transcriptMaximumWordsPerSecond out of range"),
		checkI(st.ConversationHardGapMs, 1_000, 24*60*60_000, "conversationHardGapMs out of range"),
		checkI(st.ConversationSoftGapMs, 1_000, 24*60*60_000, "conversationSoftGapMs out of range"),
		checkI(st.ConversationMinimumMs, 1_000, 60*60_000, "conversationMinimumMs out of range"),
		checkI(st.ConversationQuietCloseMs, 1_000, 24*60*60_000, "conversationQuietCloseMs out of range"),
		checkF(st.ConversationValleyQuantile, 0, 1, "conversationValleyQuantile out of range"),
		checkF(st.ConversationSemanticSimilarityThr, -1, 1, "conversationSemanticSimilarityThreshold out of range"),
		checkF(st.ConversationSemanticValleyProminence, 0, 2, "conversationSemanticValleyProminence out of range"),
		checkI(int64(st.ConversationSemanticContextSegments), 1, 20, "conversationSemanticContextSegments out of range"),
		checkI(st.ConversationMaximumMs, 60_000, 24*60*60_000, "conversationMaximumMs out of range"),
		checkI(int64(st.ConversationMaximumCharacters), 1_000, 2_000_000, "conversationMaximumCharacters out of range"),
		checkI(int64(st.ConversationPreviewMinCharacters), 1, 2_000_000, "conversationPreviewMinCharacters out of range"),
		checkI(int64(st.ConversationPreviewRefreshChars), 1, 2_000_000, "conversationPreviewRefreshCharacters out of range"),
		checkI(st.ConversationPreviewMinIntervalMs, 0, 24*60*60_000, "conversationPreviewMinIntervalMs out of range"),
		checkI(int64(st.ConversationPreviewFullCharacters), 1, 2_000_000, "conversationPreviewFullCharacters out of range"),
		checkI(st.MinAIAudioMs, 0, 24*60*60_000, "minAiAudioMs out of range"),
		checkI(int64(st.MinNewMaterialChars), 1, 1_000_000, "minNewMaterialChars out of range"),
		checkI(st.MinMemoryEvidenceMs, 0, 24*60*60_000, "minMemoryEvidenceMs out of range"),
		checkI(int64(st.MinMemoryEvidenceChars), 0, 1_000_000, "minMemoryEvidenceChars out of range"),
		checkI(int64(st.MaxConsolidationInputChars), 1_000, 2_000_000, "maxConsolidationInputChars out of range"),
		checkI(int64(st.MaxConsolidationConversations), 1, 200, "maxConsolidationConversations out of range"),
		checkI(int64(st.MaxMemoryContinuationCandidates), 0, 32, "maxMemoryContinuationCandidates out of range"),
		checkI(st.MemoryContinuationLookbackMs, 0, 30*24*60*60_000, "memoryContinuationLookbackMs out of range"),
		checkI(st.MaxConsolidationLatencyMs, 0, 7*24*60*60_000, "maxConsolidationLatencyMs out of range"),
		checkI(st.MemoryOccasionGapMs, 0, 24*60*60_000, "memoryOccasionGapMs out of range"),
		checkI(st.MemorySettleMs, 0, 24*60*60_000, "memorySettleMs out of range"),
		checkI(st.MemoryOccasionMaxWaitMs, 60_000, 7*24*60*60_000, "memoryOccasionMaxWaitMs out of range"),
		checkF(st.MemoryDedupeSimilarityThreshold, 0, 1, "memoryDedupeSimilarityThreshold out of range"),
		checkI(st.MemoryDedupeWindowMs, 0, 30*24*60*60_000, "memoryDedupeWindowMs out of range"),
		checkI(int64(st.MemoryDedupeMaxPairsPerRun), 0, 500, "memoryDedupeMaxPairsPerRun out of range"),
		checkI(int64(st.MemoryDedupeNeighbours), 1, 50, "memoryDedupeNeighbours out of range"),
		checkI(int64(st.ConsolidationMaxFailures), 1, 100, "consolidationMaxFailures out of range"),
	}
	for _, err := range checks {
		if err != nil {
			return err
		}
	}
	if st.SpeakerClusterContinuityThreshold > st.SpeakerClusterThreshold {
		return httperr.New(http.StatusBadRequest, "INVALID_SPEAKER_LIMITS", "The continuity match threshold must not exceed the plain cluster match threshold.")
	}
	if st.VoiceEnrollFloor > st.VoiceMatchThreshold {
		return httperr.New(http.StatusBadRequest, "INVALID_SPEAKER_LIMITS", "The bar for treating a voice as a new person must not exceed the bar for recognising a known one, or every voice would become a new person.")
	}
	if st.VoiceRepairThreshold > st.VoiceMatchThreshold {
		return httperr.New(http.StatusBadRequest, "INVALID_SPEAKER_LIMITS", "The duplicate-repair threshold must not exceed the voice match threshold.")
	}
	if st.MaxConsolidationInputChars < st.MinNewMaterialChars {
		return httperr.New(http.StatusBadRequest, "INVALID_MATERIAL_LIMITS", "The consolidation input limit must not be lower than the material threshold.")
	}
	if st.ConversationMinimumMs >= st.ConversationHardGapMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The minimum conversation duration must be shorter than the hard boundary gap.")
	}
	if st.ConversationSoftGapMs >= st.ConversationHardGapMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The soft conversation gap must be shorter than the hard boundary gap.")
	}
	if st.ConversationQuietCloseMs < st.ConversationHardGapMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The quiet-close delay must be at least as long as the hard boundary gap, or a conversation closes while a pause could still continue it.")
	}
	if st.ConversationMaximumMs <= st.ConversationMinimumMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The maximum conversation duration must be longer than the minimum duration.")
	}
	if st.ConversationMaximumCharacters > st.MaxConsolidationInputChars {
		return httperr.New(http.StatusBadRequest, "INVALID_MATERIAL_LIMITS", "The conversation character limit must not exceed the consolidation input limit.")
	}
	if st.ConversationPreviewMinCharacters > st.ConversationMaximumCharacters {
		return httperr.New(http.StatusBadRequest, "INVALID_MATERIAL_LIMITS", "The preview threshold must not exceed the conversation character limit, or no conversation would ever be previewed.")
	}
	if st.MemoryOccasionGapMs < st.ConversationHardGapMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The occasion gap must be at least as long as the hard boundary gap, or fragments of one sitting could never be joined.")
	}
	if st.MemorySettleMs < st.ConversationHardGapMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The settle delay must be at least as long as the hard boundary gap, or a fragment is written up before the pause after it has ended.")
	}
	if st.MemoryOccasionMaxWaitMs <= st.MemorySettleMs {
		return httperr.New(http.StatusBadRequest, "INVALID_CONVERSATION_LIMITS", "The maximum occasion wait must be longer than the settle delay.")
	}
	return nil
}

func (s *Service) Update(ctx context.Context, patch map[string]any) (Settings, error) {
	base := s.Get(ctx)
	curMap := map[string]any{}
	b, _ := json.Marshal(base)
	_ = json.Unmarshal(b, &curMap)

	cleanPatch := map[string]any{}
	for k, v := range patch {
		if _, ok := curMap[k]; !ok {
			return Settings{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Unknown processing setting: "+k)
		}
		curMap[k] = v
		cleanPatch[k] = v
	}
	var next Settings
	merged, err := json.Marshal(curMap)
	if err != nil {
		return Settings{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Processing settings are invalid.")
	}
	if err := json.Unmarshal(merged, &next); err != nil {
		return Settings{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Processing settings are invalid.")
	}
	if err := Validate(next); err != nil {
		return Settings{}, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return Settings{}, err
	}
	defer tx.Rollback()
	for k, v := range cleanPatch {
		vb, _ := json.Marshal(v)
		if _, err := tx.ExecContext(ctx, `INSERT INTO app_settings (key, value_json) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
			k, string(vb)); err != nil {
			return Settings{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return Settings{}, err
	}
	return s.Get(ctx), nil
}
