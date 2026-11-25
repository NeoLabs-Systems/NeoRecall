// Package config loads, validates, and exposes NeoRecall's runtime configuration
// and filesystem layout. Environment variable names, bounds, and cross-field
// invariants match the Node server so existing .env files keep working.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/runtimecfg"
)

// Version is the NeoRecall build version (mutable var so -ldflags -X overrides it cleanly).
var Version = "0.1.4-beta.14"

const (
	LLMPromptReserveTokens = 512
	DefaultEmbeddingModel  = "Xenova/multilingual-e5-small"
	DefaultEmbeddingDims   = 384
	ChunkReceiptBatchLimit = 500
	DefaultServiceLabel    = "systems.neolabs.neorecall"
)

// Paths holds the private runtime directories (0700) and files (0600).
type Paths struct {
	Home         string
	Data         string
	Models       string
	AudioTmp     string
	AudioWork    string
	ImportTmp    string
	Context      string
	Logs         string
	Backups      string
	CloudPending string
	Database     string
	EnvFile      string
	SecretKey    string
	PIDFile      string
	UpdateStatus string
	RuntimeDir   string
}

func expandHome(val, userHome string) string {
	val = strings.TrimSpace(val)
	if val == "" {
		return filepath.Join(userHome, ".neorecall")
	}
	if val == "~" {
		return userHome
	}
	if strings.HasPrefix(val, "~"+string(filepath.Separator)) || strings.HasPrefix(val, "~/") {
		return filepath.Join(userHome, val[2:])
	}
	abs, err := filepath.Abs(val)
	if err != nil {
		return val
	}
	return abs
}

// ResolvePaths computes all runtime paths without creating them.
func ResolvePaths(getenv func(string) string, userHome string) Paths {
	home := expandHome(getenv("NEORECALL_HOME"), userHome)
	dbPath := strings.TrimSpace(getenv("NEORECALL_DATABASE_PATH"))
	if dbPath == "" {
		dbPath = filepath.Join(home, "data", "neorecall.sqlite3")
	}
	return Paths{
		Home:         home,
		Data:         filepath.Join(home, "data"),
		Models:       filepath.Join(home, "models"),
		AudioTmp:     filepath.Join(home, "audio_tmp"),
		AudioWork:    filepath.Join(home, "audio_work"),
		ImportTmp:    filepath.Join(home, "import_tmp"),
		Context:      filepath.Join(home, "context"),
		Logs:         filepath.Join(home, "logs"),
		Backups:      filepath.Join(home, "backups"),
		CloudPending: filepath.Join(home, "cloud_pending"),
		Database:     dbPath,
		EnvFile:      filepath.Join(home, ".env"),
		SecretKey:    filepath.Join(home, "data", "secret.key"),
		PIDFile:      filepath.Join(home, "data", "neorecall.pid"),
		UpdateStatus: filepath.Join(home, "data", "update-status.json"),
		RuntimeDir:   filepath.Join(home, "runtime"),
	}
}

// Ensure creates all NeoRecall private directories with 0700 permissions.
func (p Paths) Ensure() error {
	for _, dir := range []string{
		p.Home, p.Data, p.Models, p.AudioTmp, p.AudioWork,
		p.ImportTmp, p.Context, p.Logs, p.Backups, p.CloudPending,
	} {
		if err := runtimecfg.EnsurePrivateDir(dir); err != nil {
			return err
		}
	}
	return nil
}

type SearchWeights struct {
	Relevance  float64
	Recency    float64
	Importance float64
}

type Config struct {
	Paths   Paths
	AppDir  string
	WebDir  string
	Landing string

	Role                string
	Host                string
	Port                int
	PublicURL           string
	AllowedOrigins      string
	TrustProxy          bool
	Production          bool
	ContainerImage      bool
	LogLevel            string
	SessionTTLMs        int64
	RegistrationEnabled bool
	AdminUsers          []string

	MaxUploadBytes                 int64
	ContextMaxFileBytes            int64
	ContextNoteMaxCharacters       int
	ContextExtractionMaxCharacters int
	ContextMaxItems                int
	ContextImageAnalysisMaxBytes   int64

	ChunkTargetMs             int
	ChunkMinMs                int
	ChunkMaxMs                int
	ChunkOverlapMs            int
	ImportPartBytes           int64
	ImportSessionContinuityMs int64
	ImportFailedTTLHours      int
	OrphanFileGraceMs         int64

	TranscriptionProvider          string
	TranscriptionAPIBaseURL        string
	TranscriptionAPIKey            string
	TranscriptionAPIModel          string
	TranscriptionAPILanguage       string
	TranscriptionAPIResponseFormat string
	TranscriptionTimeoutMs         int
	TranscriptionPollIntervalMs    int

	AudioPreprocessEnabled        bool
	AudioPreprocessTarget         string
	AudioPreprocessHighpassHz     int
	AudioPreprocessDenoiseEnabled bool
	AudioPreprocessDenoiseDb      float64
	AudioPreprocessDenoiseFloorDb float64
	AudioPreprocessNormalizer     string
	AudioPreprocessMaxGain        float64
	AudioPreprocessTargetLufs     float64
	AudioPreprocessTruePeakDb     float64
	AudioPreprocessLimiterEnabled bool
	AudioPreprocessLimiterPeak    float64
	AudioPreprocessSampleRate     int
	AudioPreprocessFormat         string
	AudioPreprocessTimeoutMs      int
	AudioPreprocessMaxDurationMs  int

	CustomVocabularyMaxTerms            int
	CustomVocabularyMaxTermLength       int
	VocabularyCorrectionMinimumLength   int
	VocabularyCorrectionMaximumDistance int
	VocabularyCorrectionSimilarity      float64
	VocabularyCorrectionAmbiguityMargin float64

	BackupEnabled       bool
	BackupDestination   string
	BackupIntervalHours int
	BackupRetain        int

	CloudUserBackupIntervalHours int
	CloudPendingMaxAgeMs         int64
	CloudLoginTimeoutMs          int64
	CloudHTTPTimeoutMs           int64
	CloudPutMaxAttempts          int
	CloudConcatTimeoutMs         int64

	DiarizationEnabled           bool
	SherpaThreads                int
	VADThreshold                 float64
	VADMinimumSpeechSeconds      float64
	VADMinimumSilenceSeconds     float64
	DiarizationMinimumOnSeconds  float64
	DiarizationMinimumOffSeconds float64
	VoiceMatchThreshold          float64
	VoiceMatchMargin             float64
	VoiceEnrollFloor             float64
	VoiceEnrollMinimumMs         int
	VoiceRepairThreshold         float64
	SpeakerRedetectDays          int
	DiarizationClusterDistance   float64
	SpeakerClusterThreshold      float64
	SpeakerClusterMergeThreshold float64
	SpeakerMinimumTurnMs         int
	SpeakerClusterMargin         float64
	SpeakerContinuityGapMs       int
	SpeakerClusterContinuityThr  float64
	SpeakerPreviewMinimumMs      int
	SpeakerPreviewMaximumMs      int
	SpeakerDisplayMinPreviewMs   int
	SpeakerPreviewMaxBytes       int64

	DedupeTokenSimilarity               float64
	DedupeTimeToleranceMs               int
	SameDeviceCoverageRatio             float64
	TranscriptRepetitionMinimumRepeats  int
	TranscriptRepetitionMaxPatternWords int
	TranscriptRepetitionMinimumCoverage float64
	TranscriptMaximumWordsPerSecond     float64

	ConversationHardGapMs                int64
	ConversationSoftGapMs                int64
	ConversationMinimumMs                int64
	ConversationQuietCloseMs             int64
	ConversationValleyQuantile           float64
	ConversationSemanticSimilarityThr    float64
	ConversationSemanticValleyProminence float64
	ConversationSemanticContextSegments  int
	ConversationMaximumMs                int64
	ConversationMaximumCharacters        int
	ConversationPreviewMinCharacters     int
	ConversationPreviewRefreshChars      int
	ConversationPreviewMinIntervalMs     int64
	ConversationPreviewFullCharacters    int

	EmbeddingModel          string
	EmbeddingDimensions     int
	RequireVector           bool
	RRFK                    int
	SemanticSimilarityFloor float64

	AskMaxSearchQueries        int
	AskTimeWindowLimit         int
	AskMemoryContextLimit      int
	AskTranscriptContextLimit  int
	AskQuotaWindowMs           int64
	AskCitationExcerptChars    int
	AskPromptReserveCharacters int
	EventOutboxPollLimit       int
	EventOutboxKeepaliveMs     int
	OAuthPendingTwoFactorTTLMs int64
	OAuthBrowserGrantTTLMs     int64
	TwoFactorLockAfterFailures int
	TwoFactorLockMs            int64
	TwoFactorRecoveryCodeCount int
	FTSMaxTerms                int
	JobRetryBaseMs             int64
	JobRetryMaxMs              int64
	WorkerHeartbeatMs          int
	WorkerLeaseRenewMs         int
	WorkerIdlePollMs           int
	AskQuotaRetentionMs        int64
	ConsolidationInterruptMs   int64
	ProcessingStalledQueueMs   int64
	ProcessingWorkerSilentMs   int64
	UsageReservationTTLMs      int64
	UsageMaxReservationTokens  int
	ConsolidationFailureBaseMs int64
	ConsolidationFailureMaxMs  int64
	CustomInstructionsMaxChars int

	SearchWeights      SearchWeights
	SearchHalfLifeDays float64

	AIProvider                   string
	LLMContextSize               int
	LLMTemperature               float64
	AIAPIBaseURL                 string
	AIAPIKey                     string
	AIAPIExtraBody               map[string]any
	AIAPIModel                   string
	AITimeoutMs                  int
	AIMaxRetries                 int
	NeoRouterRequestTimeoutMs    int
	NeoRouterSignInTTLMs         int64
	ReindexBatchSize             int
	NeoRouterOfferCacheMs        int64
	AIConsolidationMaxOutTokens  int
	ConsolidationWindowChars     int
	AIPreviewMaxOutTokens        int
	MinConsolidationIntervalMs   int64
	MaxConsolidationLatencyMs    int64
	ConsolidationMaxFailures     int
	MinAIAudioMs                 int64
	MinNewMaterialChars          int
	MinMemoryEvidenceMs          int64
	MinMemoryEvidenceChars       int
	MaxConsolidationInputChars   int
	MaxConsolidationConvs        int
	MemoryOccasionGapMs          int64
	MemorySettleMs               int64
	MemoryOccasionMaxWaitMs      int64
	MaxMemoryContinuationCands   int
	MemoryContinuationLookbackMs int64
	MemoryMergeMaxItems          int
	MemoryDedupeEnabled          bool
	MemoryDedupeSimilarityThr    float64
	MemoryDedupeWindowMs         int64
	MemoryDedupeMaxPairsPerRun   int
	MemoryDedupeNeighbours       int
	AskMaxPerHour                int
	AskBurstPerMinute            int

	AITokens4h                 int
	AITokensWeekly             int
	TranscriptionSeconds4h     int
	TranscriptionSecondsWeekly int

	SchedulerIntervalMs        int
	JobLeaseMs                 int64
	JobMaxAttempts             int
	DiagnosticRetentionDays    int
	DiagnosticMaxEventsPerUser int
	DiagnosticExportMaxEvents  int

	PlaudClientID     string
	PlaudClientSecret string
	PlaudAPIHost      string
}

type reader struct {
	getenv func(string) string
	err    error
}

func (r *reader) str(name, def string) string {
	v := r.getenv(name)
	if v == "" {
		return def
	}
	return v
}

func (r *reader) int(name string, def, min, max int) int {
	if r.err != nil {
		return def
	}
	raw := strings.TrimSpace(r.getenv(name))
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v < min || v > max {
		r.err = fmt.Errorf("%s must be an integer between %d and %d", name, min, max)
		return def
	}
	return v
}

func (r *reader) int64(name string, def, min, max int64) int64 {
	if r.err != nil {
		return def
	}
	raw := strings.TrimSpace(r.getenv(name))
	if raw == "" {
		return def
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || v < min || v > max {
		r.err = fmt.Errorf("%s must be an integer between %d and %d", name, min, max)
		return def
	}
	return v
}

func (r *reader) num(name string, def, min, max float64) float64 {
	if r.err != nil {
		return def
	}
	raw := strings.TrimSpace(r.getenv(name))
	if raw == "" {
		return def
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < min || v > max {
		r.err = fmt.Errorf("%s must be a number between %g and %g", name, min, max)
		return def
	}
	return v
}

func (r *reader) bool(name string, def bool) bool {
	if r.err != nil {
		return def
	}
	raw := strings.TrimSpace(r.getenv(name))
	if raw == "" {
		return def
	}
	b := runtimecfg.Bool(raw, true)
	if b != runtimecfg.Bool(raw, false) {
		r.err = fmt.Errorf("%s must be true or false", name)
		return def
	}
	return b
}

func (r *reader) enum(name, def string, allowed ...string) string {
	if r.err != nil {
		return def
	}
	raw := strings.TrimSpace(r.getenv(name))
	val := def
	if raw != "" {
		val = strings.ToLower(raw)
	}
	for _, a := range allowed {
		if val == a {
			return val
		}
	}
	r.err = fmt.Errorf("%s must be one of %s", name, strings.Join(allowed, ", "))
	return def
}

func (r *reader) jsonObj(name string) map[string]any {
	if r.err != nil {
		return nil
	}
	raw := strings.TrimSpace(r.getenv(name))
	if raw == "" {
		return nil
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(raw), &obj); err != nil || obj == nil {
		r.err = fmt.Errorf(`%s must be a JSON object, for example {"chat_template_kwargs":{"enable_thinking":false}}`, name)
		return nil
	}
	return obj
}

func stripTrailingSlashes(s string) string {
	return strings.TrimRight(strings.TrimSpace(s), "/")
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func resolveAppDir(envDir, cwd, runtimeDir, userHome string) string {
	if strings.TrimSpace(envDir) != "" {
		return strings.TrimSpace(envDir)
	}
	hasAssets := func(dir string) bool {
		if dir == "" {
			return false
		}
		if _, err := os.Stat(filepath.Join(dir, "flutter_app", "build", "web", "index.html")); err == nil {
			return true
		}
		if _, err := os.Stat(filepath.Join(dir, "landing", "index.html")); err == nil {
			return true
		}
		return false
	}
	var exeDir string
	if exe, err := os.Executable(); err == nil {
		exeDir = filepath.Dir(exe)
	}
	for _, cand := range []string{
		cwd,
		exeDir,
		filepath.Join(runtimeDir, "app"),
		filepath.Join(userHome, "NeoRecall"),
	} {
		if hasAssets(cand) {
			return cand
		}
	}
	return cwd
}

// Load parses and validates the NeoRecall configuration.
func Load(getenv func(string) string, userHome, cwd string) (Config, error) {
	var c Config
	r := &reader{getenv: getenv}
	c.Paths = ResolvePaths(getenv, userHome)

	c.AppDir = resolveAppDir(getenv("NEORECALL_APP_DIR"), cwd, c.Paths.RuntimeDir, userHome)
	c.WebDir = firstNonEmpty(getenv("NEORECALL_WEB_DIR"), filepath.Join(c.AppDir, "flutter_app", "build", "web"))
	c.Landing = firstNonEmpty(getenv("NEORECALL_LANDING_DIR"), filepath.Join(c.AppDir, "landing"))

	c.Role = strings.ToLower(strings.TrimSpace(getenv("NEORECALL_ROLE")))
	c.Production = strings.EqualFold(strings.TrimSpace(getenv("NODE_ENV")), "production") ||
		strings.EqualFold(strings.TrimSpace(getenv("NEORECALL_ENV")), "production")
	c.ContainerImage = r.bool("NEORECALL_CONTAINER_IMAGE", false)

	c.Host = r.str("NEORECALL_HOST", "127.0.0.1")
	c.Port = r.int("NEORECALL_PORT", 4500, 1, 65535)
	c.PublicURL = stripTrailingSlashes(getenv("NEORECALL_PUBLIC_URL"))
	c.AllowedOrigins = strings.TrimSpace(getenv("NEORECALL_ALLOWED_ORIGINS"))
	c.TrustProxy = r.bool("NEORECALL_TRUST_PROXY", false)
	c.LogLevel = r.str("NEORECALL_LOG_LEVEL", "info")
	c.SessionTTLMs = r.int64("NEORECALL_SESSION_TTL_MS", 30*24*60*60*1000, 60_000, math.MaxInt64)
	c.RegistrationEnabled = r.bool("NEORECALL_REGISTRATION_ENABLED", true)

	for _, name := range strings.Split(getenv("NEORECALL_ADMIN_USERS"), ",") {
		if trimmed := strings.TrimSpace(name); trimmed != "" {
			c.AdminUsers = append(c.AdminUsers, trimmed)
		}
	}

	c.MaxUploadBytes = r.int64("MAX_UPLOAD_BYTES", 32*1024*1024, 1024, math.MaxInt64)
	c.ContextMaxFileBytes = r.int64("NEORECALL_CONTEXT_MAX_FILE_BYTES", 32*1024*1024, 1024, math.MaxInt64)
	c.ContextNoteMaxCharacters = r.int("NEORECALL_CONTEXT_NOTE_MAX_CHARACTERS", 20_000, 1, math.MaxInt)
	c.ContextExtractionMaxCharacters = r.int("NEORECALL_CONTEXT_EXTRACTION_MAX_CHARACTERS", 500_000, 1_000, math.MaxInt)
	c.ContextMaxItems = r.int("NEORECALL_CONTEXT_MAX_ITEMS", 200, 1, 10_000)
	c.ContextImageAnalysisMaxBytes = r.int64("NEORECALL_CONTEXT_IMAGE_ANALYSIS_MAX_BYTES", 5*1024*1024, 1024, math.MaxInt64)

	c.ChunkMinMs = r.int("NEORECALL_CHUNK_MIN_MS", 15_000, 1_000, math.MaxInt)
	c.ChunkMaxMs = r.int("NEORECALL_CHUNK_MAX_MS", 120_000, max(1, c.ChunkMinMs), math.MaxInt)
	c.ChunkTargetMs = r.int("NEORECALL_CHUNK_TARGET_MS", 30_000, c.ChunkMinMs, c.ChunkMaxMs)
	c.ChunkOverlapMs = r.int("NEORECALL_CHUNK_OVERLAP_MS", 2_000, 0, max(0, c.ChunkMaxMs-1))
	c.ImportPartBytes = r.int64("NEORECALL_IMPORT_PART_BYTES", 8*1024*1024, 64*1024, math.MaxInt64)
	c.ImportSessionContinuityMs = r.int64("NEORECALL_IMPORT_SESSION_CONTINUITY_MS", 600_000, 0, math.MaxInt64)
	c.ImportFailedTTLHours = r.int("NEORECALL_IMPORT_FAILED_TTL_HOURS", 24, 1, math.MaxInt)
	c.OrphanFileGraceMs = r.int64("NEORECALL_ORPHAN_FILE_GRACE_MS", 60_000, 1_000, math.MaxInt64)

	c.TranscriptionProvider = r.str("TRANSCRIPTION_PROVIDER", "openai-compatible")
	c.TranscriptionAPIBaseURL = stripTrailingSlashes(getenv("TRANSCRIPTION_API_BASE_URL"))
	c.TranscriptionAPIKey = getenv("TRANSCRIPTION_API_KEY")
	c.TranscriptionAPIModel = getenv("TRANSCRIPTION_API_MODEL")
	c.TranscriptionAPILanguage = getenv("TRANSCRIPTION_API_LANGUAGE")
	c.TranscriptionAPIResponseFormat = getenv("TRANSCRIPTION_API_RESPONSE_FORMAT")
	c.TranscriptionTimeoutMs = r.int("TRANSCRIPTION_REQUEST_TIMEOUT_MS", 1_800_000, 1_000, math.MaxInt)
	c.TranscriptionPollIntervalMs = r.int("TRANSCRIPTION_POLL_INTERVAL_MS", 1_000, 250, 60_000)

	c.AudioPreprocessEnabled = r.bool("NEORECALL_AUDIO_PREPROCESS_ENABLED", true)
	c.AudioPreprocessTarget = r.enum("NEORECALL_AUDIO_PREPROCESS_TARGET", "stt", "stt", "stt+analysis")
	c.AudioPreprocessHighpassHz = r.int("NEORECALL_AUDIO_PREPROCESS_HIGHPASS_HZ", 70, 0, 300)
	c.AudioPreprocessDenoiseEnabled = r.bool("NEORECALL_AUDIO_PREPROCESS_DENOISE_ENABLED", true)
	c.AudioPreprocessDenoiseDb = r.num("NEORECALL_AUDIO_PREPROCESS_DENOISE_DB", 6, 0.01, 97)
	c.AudioPreprocessDenoiseFloorDb = r.num("NEORECALL_AUDIO_PREPROCESS_DENOISE_FLOOR_DB", -40, -80, -20)
	c.AudioPreprocessNormalizer = r.enum("NEORECALL_AUDIO_PREPROCESS_NORMALIZER", "dynaudnorm", "dynaudnorm", "loudnorm", "speechnorm", "off")
	c.AudioPreprocessMaxGain = r.num("NEORECALL_AUDIO_PREPROCESS_MAX_GAIN", 8, 1, 100)
	c.AudioPreprocessTargetLufs = r.num("NEORECALL_AUDIO_PREPROCESS_TARGET_LUFS", -18, -40, -5)
	c.AudioPreprocessTruePeakDb = r.num("NEORECALL_AUDIO_PREPROCESS_TRUE_PEAK_DB", -2, -9, 0)
	c.AudioPreprocessLimiterEnabled = r.bool("NEORECALL_AUDIO_PREPROCESS_LIMITER_ENABLED", true)
	c.AudioPreprocessLimiterPeak = r.num("NEORECALL_AUDIO_PREPROCESS_LIMITER_PEAK", 0.95, 0.0625, 1)
	c.AudioPreprocessSampleRate = r.int("NEORECALL_AUDIO_PREPROCESS_SAMPLE_RATE", 16_000, 8_000, 48_000)
	c.AudioPreprocessFormat = r.enum("NEORECALL_AUDIO_PREPROCESS_FORMAT", "wav", "wav", "flac")
	c.AudioPreprocessTimeoutMs = r.int("NEORECALL_AUDIO_PREPROCESS_TIMEOUT_MS", 120_000, 1_000, 600_000)
	c.AudioPreprocessMaxDurationMs = r.int("NEORECALL_AUDIO_PREPROCESS_MAX_DURATION_MS", 1_800_000, 0, 86_400_000)

	c.CustomVocabularyMaxTerms = r.int("NEORECALL_CUSTOM_VOCABULARY_MAX_TERMS", 100, 1, 1_000)
	c.CustomVocabularyMaxTermLength = r.int("NEORECALL_CUSTOM_VOCABULARY_MAX_TERM_LENGTH", 120, 1, 500)
	c.VocabularyCorrectionMinimumLength = r.int("NEORECALL_VOCABULARY_CORRECTION_MIN_LENGTH", 8, 4, 100)
	c.VocabularyCorrectionMaximumDistance = r.int("NEORECALL_VOCABULARY_CORRECTION_MAX_DISTANCE", 2, 1, 5)
	c.VocabularyCorrectionSimilarity = r.num("NEORECALL_VOCABULARY_CORRECTION_SIMILARITY", 0.84, 0.5, 1)
	c.VocabularyCorrectionAmbiguityMargin = r.num("NEORECALL_VOCABULARY_CORRECTION_AMBIGUITY_MARGIN", 0.08, 0, 1)

	c.BackupEnabled = r.bool("NEORECALL_BACKUP_ENABLED", true)
	c.BackupDestination = r.str("NEORECALL_BACKUP_DESTINATION", "local")
	c.BackupIntervalHours = r.int("NEORECALL_BACKUP_INTERVAL_HOURS", 24, 1, 24*30)
	c.BackupRetain = r.int("NEORECALL_BACKUP_RETAIN", 3, 1, 365)

	c.CloudUserBackupIntervalHours = r.int("NEORECALL_CLOUD_USER_BACKUP_INTERVAL_HOURS", 24, 1, 24*30)
	c.CloudPendingMaxAgeMs = r.int64("NEORECALL_CLOUD_PENDING_MAX_AGE_MS", 7*24*60*60_000, 60_000, math.MaxInt64)
	c.CloudLoginTimeoutMs = r.int64("NEORECALL_CLOUD_LOGIN_TIMEOUT_MS", 20*60_000, 30_000, 60*60_000)
	c.CloudHTTPTimeoutMs = r.int64("NEORECALL_CLOUD_HTTP_TIMEOUT_MS", 120_000, 5_000, 1_800_000)
	c.CloudPutMaxAttempts = r.int("NEORECALL_CLOUD_PUT_MAX_ATTEMPTS", 8, 1, 50)
	c.CloudConcatTimeoutMs = r.int64("NEORECALL_CLOUD_CONCAT_TIMEOUT_MS", 10*60_000, 10_000, 60*60_000)

	c.DiarizationEnabled = r.bool("NEORECALL_DIARIZATION_ENABLED", true)
	c.SherpaThreads = r.int("NEORECALL_SHERPA_THREADS", 2, 1, 128)
	c.VADThreshold = r.num("NEORECALL_VAD_THRESHOLD", 0.5, 0, 1)
	c.VADMinimumSpeechSeconds = r.num("NEORECALL_VAD_MIN_SPEECH_SECONDS", 0.25, 0, math.MaxFloat64)
	c.VADMinimumSilenceSeconds = r.num("NEORECALL_VAD_MIN_SILENCE_SECONDS", 0.5, 0, math.MaxFloat64)
	c.DiarizationMinimumOnSeconds = r.num("NEORECALL_DIARIZATION_MIN_ON_SECONDS", 0.3, 0, math.MaxFloat64)
	c.DiarizationMinimumOffSeconds = r.num("NEORECALL_DIARIZATION_MIN_OFF_SECONDS", 0.2, 0, math.MaxFloat64)
	c.VoiceMatchThreshold = r.num("NEORECALL_VOICE_MATCH_THRESHOLD", 0.62, -1, 1)
	c.VoiceMatchMargin = r.num("NEORECALL_VOICE_MATCH_MARGIN", 0.05, 0, 2)
	c.VoiceEnrollFloor = r.num("NEORECALL_VOICE_ENROLL_FLOOR", 0.45, -1, 1)
	c.VoiceEnrollMinimumMs = r.int("NEORECALL_VOICE_ENROLL_MIN_MS", 3_000, 0, 120_000)
	c.VoiceRepairThreshold = r.num("NEORECALL_VOICE_REPAIR_THRESHOLD", 0.50, -1, 1)
	c.SpeakerRedetectDays = r.int("NEORECALL_SPEAKER_REDETECT_DAYS", 30, 1, 3650)
	c.DiarizationClusterDistance = r.num("NEORECALL_DIARIZATION_CLUSTER_DISTANCE", 0.65, 0, 2)
	c.SpeakerClusterThreshold = r.num("NEORECALL_SPEAKER_CLUSTER_THRESHOLD", 0.52, -1, 1)
	c.SpeakerClusterMergeThreshold = r.num("NEORECALL_SPEAKER_CLUSTER_MERGE_THRESHOLD", 0.55, -1, 1)
	c.SpeakerMinimumTurnMs = r.int("NEORECALL_SPEAKER_MINIMUM_TURN_MS", 500, 0, 60_000)
	c.SpeakerClusterMargin = r.num("NEORECALL_SPEAKER_CLUSTER_MARGIN", 0.05, 0, 2)
	c.SpeakerContinuityGapMs = r.int("NEORECALL_SPEAKER_CONTINUITY_GAP_MS", 4_000, 0, math.MaxInt)
	c.SpeakerClusterContinuityThr = r.num("NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD", 0.42, -1, 1)
	c.SpeakerPreviewMinimumMs = r.int("NEORECALL_SPEAKER_PREVIEW_MIN_MS", 1_000, 1_000, 10_000)
	c.SpeakerPreviewMaximumMs = r.int("NEORECALL_SPEAKER_PREVIEW_MAX_MS", 10_000, max(1_000, c.SpeakerPreviewMinimumMs), 10_000)
	c.SpeakerDisplayMinPreviewMs = r.int("NEORECALL_SPEAKER_DISPLAY_MIN_PREVIEW_MS", 10_000, 1_000, 10_000)
	c.SpeakerPreviewMaxBytes = r.int64("NEORECALL_SPEAKER_PREVIEW_MAX_BYTES", 1024*1024, 320_044, math.MaxInt64)

	c.DedupeTokenSimilarity = r.num("NEORECALL_DEDUPE_TOKEN_SIMILARITY", 0.82, 0, 1)
	c.DedupeTimeToleranceMs = r.int("NEORECALL_DEDUPE_TIME_TOLERANCE_MS", 2500, 0, math.MaxInt)
	c.SameDeviceCoverageRatio = r.num("NEORECALL_SAME_DEVICE_COVERAGE_RATIO", 0.5, 0, 1)
	c.TranscriptRepetitionMinimumRepeats = r.int("NEORECALL_TRANSCRIPT_REPETITION_MIN_REPEATS", 8, 3, 1_000)
	c.TranscriptRepetitionMaxPatternWords = r.int("NEORECALL_TRANSCRIPT_REPETITION_MAX_PATTERN_WORDS", 8, 1, 32)
	c.TranscriptRepetitionMinimumCoverage = r.num("NEORECALL_TRANSCRIPT_REPETITION_MIN_COVERAGE", 0.8, 0.5, 1)
	c.TranscriptMaximumWordsPerSecond = r.num("NEORECALL_TRANSCRIPT_MAXIMUM_WORDS_PER_SECOND", 5, 1, 50)
	if getenv("NEORECALL_TRANSCRIPT_MAX_WORDS_PER_SECOND") != "" {
		c.TranscriptMaximumWordsPerSecond = r.num("NEORECALL_TRANSCRIPT_MAX_WORDS_PER_SECOND", 5, 1, 50)
	}

	c.ConversationHardGapMs = r.int64("NEORECALL_CONVERSATION_HARD_GAP_MS", 600_000, 1_000, math.MaxInt64)
	c.ConversationSoftGapMs = r.int64("NEORECALL_CONVERSATION_SOFT_GAP_MS", 300_000, 1_000, math.MaxInt64)
	c.ConversationMinimumMs = r.int64("NEORECALL_CONVERSATION_MINIMUM_MS", 300_000, 1_000, math.MaxInt64)
	c.ConversationQuietCloseMs = r.int64("NEORECALL_CONVERSATION_QUIET_CLOSE_MS", 600_000, 1_000, math.MaxInt64)
	c.ConversationValleyQuantile = r.num("NEORECALL_CONVERSATION_VALLEY_QUANTILE", 0.25, 0, 1)
	c.ConversationSemanticSimilarityThr = r.num("NEORECALL_CONVERSATION_SEMANTIC_SIMILARITY_THRESHOLD", 0.58, -1, 1)
	c.ConversationSemanticValleyProminence = r.num("NEORECALL_CONVERSATION_SEMANTIC_VALLEY_PROMINENCE", 0.1, 0, 2)
	c.ConversationSemanticContextSegments = r.int("NEORECALL_CONVERSATION_SEMANTIC_CONTEXT_SEGMENTS", 3, 1, 20)
	c.ConversationMaximumMs = r.int64("NEORECALL_CONVERSATION_MAXIMUM_MS", 4*60*60_000, 60_000, math.MaxInt64)
	c.ConversationMaximumCharacters = r.int("NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS", 200_000, 1_000, math.MaxInt)
	c.ConversationPreviewMinCharacters = r.int("NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS", 300, 1, math.MaxInt)
	c.ConversationPreviewRefreshChars = r.int("NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS", 600, 1, math.MaxInt)
	c.ConversationPreviewMinIntervalMs = r.int64("NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS", 60_000, 0, math.MaxInt64)
	c.ConversationPreviewFullCharacters = r.int("NEORECALL_CONVERSATION_PREVIEW_FULL_CHARACTERS", 20_000, 1, math.MaxInt)

	c.EmbeddingModel = r.str("NEORECALL_EMBEDDING_MODEL", DefaultEmbeddingModel)
	c.EmbeddingDimensions = r.int("NEORECALL_EMBEDDING_DIMENSIONS", DefaultEmbeddingDims, 1, math.MaxInt)
	c.RequireVector = r.bool("NEORECALL_REQUIRE_VECTOR", c.Production)
	c.RRFK = r.int("NEORECALL_RRF_K", 60, 1, math.MaxInt)
	c.SemanticSimilarityFloor = r.num("NEORECALL_SEMANTIC_SIMILARITY_FLOOR", 0.62, 0, 1)

	relW := r.num("NEORECALL_SEARCH_RELEVANCE_WEIGHT", 0.5, 0, math.MaxFloat64)
	recW := r.num("NEORECALL_SEARCH_RECENCY_WEIGHT", 0.25, 0, math.MaxFloat64)
	impW := r.num("NEORECALL_SEARCH_IMPORTANCE_WEIGHT", 0.25, 0, math.MaxFloat64)
	wTot := relW + recW + impW
	if wTot <= 0 && r.err == nil {
		r.err = errors.New("at least one search weight must be greater than zero")
	} else if wTot > 0 {
		c.SearchWeights = SearchWeights{Relevance: relW / wTot, Recency: recW / wTot, Importance: impW / wTot}
	}
	c.SearchHalfLifeDays = r.num("NEORECALL_SEARCH_HALF_LIFE_DAYS", 30, 0.01, math.MaxFloat64)

	c.AskMaxSearchQueries = r.int("NEORECALL_ASK_MAX_SEARCH_QUERIES", 3, 1, 8)
	c.AskTimeWindowLimit = r.int("NEORECALL_ASK_TIME_WINDOW_LIMIT", 40, 1, 200)
	c.AskMemoryContextLimit = r.int("NEORECALL_ASK_MEMORY_CONTEXT_LIMIT", 12, 1, 100)
	c.AskTranscriptContextLimit = r.int("NEORECALL_ASK_TRANSCRIPT_CONTEXT_LIMIT", 4, 0, 100)
	c.AskQuotaWindowMs = r.int64("NEORECALL_ASK_QUOTA_WINDOW_MS", 60*60_000, 60_000, math.MaxInt64)
	c.AskCitationExcerptChars = r.int("NEORECALL_ASK_CITATION_EXCERPT_CHARS", 240, 40, 4_000)
	c.AskPromptReserveCharacters = r.int("NEORECALL_ASK_PROMPT_RESERVE_CHARACTERS", 1_000, 100, math.MaxInt)
	c.EventOutboxPollLimit = r.int("NEORECALL_EVENT_OUTBOX_POLL_LIMIT", 100, 1, 1_000)
	c.EventOutboxKeepaliveMs = r.int("NEORECALL_EVENT_OUTBOX_KEEPALIVE_MS", 15_000, 1_000, math.MaxInt)
	c.OAuthPendingTwoFactorTTLMs = r.int64("NEORECALL_OAUTH_PENDING_2FA_TTL_MS", 5*60_000, 30_000, math.MaxInt64)
	c.OAuthBrowserGrantTTLMs = r.int64("NEORECALL_OAUTH_BROWSER_GRANT_TTL_MS", 15*60_000, 30_000, math.MaxInt64)
	c.TwoFactorLockAfterFailures = r.int("NEORECALL_TWO_FACTOR_LOCK_AFTER_FAILURES", 5, 1, 50)
	c.TwoFactorLockMs = r.int64("NEORECALL_TWO_FACTOR_LOCK_MS", 5*60_000, 1_000, math.MaxInt64)
	c.TwoFactorRecoveryCodeCount = r.int("NEORECALL_TWO_FACTOR_RECOVERY_CODE_COUNT", 10, 1, 50)
	c.FTSMaxTerms = r.int("NEORECALL_FTS_MAX_TERMS", 30, 1, 200)
	c.JobRetryBaseMs = r.int64("NEORECALL_JOB_RETRY_BASE_MS", 5_000, 100, math.MaxInt64)
	c.JobRetryMaxMs = r.int64("NEORECALL_JOB_RETRY_MAX_MS", 15*60_000, 1_000, math.MaxInt64)
	c.WorkerHeartbeatMs = r.int("NEORECALL_WORKER_HEARTBEAT_MS", 5_000, 500, math.MaxInt)
	c.WorkerLeaseRenewMs = r.int("NEORECALL_WORKER_LEASE_RENEW_MS", 30_000, 1_000, math.MaxInt)
	c.WorkerIdlePollMs = r.int("NEORECALL_WORKER_IDLE_POLL_MS", 500, 50, math.MaxInt)
	c.AskQuotaRetentionMs = r.int64("NEORECALL_ASK_QUOTA_RETENTION_MS", 2*60*60_000, 60_000, math.MaxInt64)
	c.ConsolidationInterruptMs = r.int64("NEORECALL_CONSOLIDATION_INTERRUPT_MS", 30*60_000, 1_000, math.MaxInt64)
	c.ProcessingStalledQueueMs = r.int64("NEORECALL_PROCESSING_STALLED_QUEUE_MS", 30*60_000, 1_000, math.MaxInt64)
	c.ProcessingWorkerSilentMs = r.int64("NEORECALL_PROCESSING_WORKER_SILENT_MS", 5*60_000, 1_000, math.MaxInt64)
	c.UsageReservationTTLMs = r.int64("NEORECALL_USAGE_RESERVATION_TTL_MS", 15*60_000, 5_000, math.MaxInt64)
	c.UsageMaxReservationTokens = r.int("NEORECALL_USAGE_MAX_RESERVATION_TOKENS", 100_000, 1, math.MaxInt)
	c.ConsolidationFailureBaseMs = r.int64("NEORECALL_CONSOLIDATION_FAILURE_BACKOFF_BASE_MS", 60_000, 1_000, math.MaxInt64)
	c.ConsolidationFailureMaxMs = r.int64("NEORECALL_CONSOLIDATION_FAILURE_BACKOFF_MAX_MS", 30*60_000, 1_000, math.MaxInt64)
	c.CustomInstructionsMaxChars = r.int("NEORECALL_CUSTOM_INSTRUCTIONS_MAX_CHARACTERS", 2_000, 0, 20_000)

	c.AIProvider = r.str("AI_PROVIDER", "openai_compatible")
	c.LLMContextSize = r.int("LLM_CONTEXT_SIZE", 16_384, 2_048, 262_144)
	c.LLMTemperature = r.num("LLM_TEMPERATURE", 0.2, 0, 2)
	c.AIAPIBaseURL = stripTrailingSlashes(getenv("AI_API_BASE_URL"))
	c.AIAPIKey = getenv("AI_API_KEY")
	c.AIAPIExtraBody = r.jsonObj("AI_API_EXTRA_BODY")
	c.AIAPIModel = getenv("AI_API_MODEL")
	c.AITimeoutMs = r.int("AI_REQUEST_TIMEOUT_MS", 1_800_000, 1_000, math.MaxInt)
	c.AIMaxRetries = r.int("AI_MAX_RETRIES", 2, 0, 10)
	c.NeoRouterRequestTimeoutMs = r.int("NEORECALL_NEOROUTER_REQUEST_TIMEOUT_MS", 20_000, 1_000, math.MaxInt)
	c.NeoRouterSignInTTLMs = r.int64("NEORECALL_NEOROUTER_SIGN_IN_TTL_MS", 600_000, 30_000, math.MaxInt64)
	c.ReindexBatchSize = r.int("NEORECALL_REINDEX_BATCH_SIZE", 20, 1, 500)
	c.NeoRouterOfferCacheMs = r.int64("NEORECALL_NEOROUTER_OFFER_CACHE_MS", 300_000, 0, math.MaxInt64)
	c.AIConsolidationMaxOutTokens = r.int("AI_CONSOLIDATION_MAX_OUTPUT_TOKENS", 8_000, 512, 200_000)
	c.ConsolidationWindowChars = r.int("NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS", 8_000, 1_000, math.MaxInt)
	c.AIPreviewMaxOutTokens = r.int("AI_PREVIEW_MAX_OUTPUT_TOKENS", 4_000, 256, 200_000)
	c.MinConsolidationIntervalMs = r.int64("NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS", 0, 0, math.MaxInt64)
	c.MaxConsolidationLatencyMs = r.int64("NEORECALL_MAX_CONSOLIDATION_LATENCY_MS", 0, 0, math.MaxInt64)
	c.ConsolidationMaxFailures = r.int("NEORECALL_CONSOLIDATION_MAX_FAILURES", 3, 1, 100)
	c.MinAIAudioMs = r.int64("NEORECALL_MIN_AI_AUDIO_MS", 0, 0, math.MaxInt64)
	c.MinNewMaterialChars = r.int("NEORECALL_MIN_NEW_MATERIAL_CHARS", 1, 1, math.MaxInt)
	c.MinMemoryEvidenceMs = r.int64("NEORECALL_MIN_MEMORY_EVIDENCE_MS", 120_000, 0, math.MaxInt64)
	c.MinMemoryEvidenceChars = r.int("NEORECALL_MIN_MEMORY_EVIDENCE_CHARS", 400, 0, math.MaxInt)
	c.MaxConsolidationInputChars = r.int("NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS", 250_000, 1_000, math.MaxInt)
	c.MaxConsolidationConvs = r.int("NEORECALL_MAX_CONSOLIDATION_CONVERSATIONS", 12, 1, 200)
	c.MemoryOccasionGapMs = r.int64("NEORECALL_MEMORY_OCCASION_GAP_MS", 15*60_000, 0, math.MaxInt64)
	c.MemorySettleMs = r.int64("NEORECALL_MEMORY_SETTLE_MS", 10*60_000, 0, math.MaxInt64)
	c.MemoryOccasionMaxWaitMs = r.int64("NEORECALL_MEMORY_OCCASION_MAX_WAIT_MS", 60*60_000, 60_000, math.MaxInt64)
	c.MaxMemoryContinuationCands = r.int("NEORECALL_MAX_MEMORY_CONTINUATION_CANDIDATES", 8, 0, 32)
	c.MemoryContinuationLookbackMs = r.int64("NEORECALL_MEMORY_CONTINUATION_LOOKBACK_MS", 2*60*60_000, 0, math.MaxInt64)
	c.MemoryMergeMaxItems = r.int("NEORECALL_MEMORY_MERGE_MAX_ITEMS", 100, 2, 500)
	c.MemoryDedupeEnabled = r.bool("NEORECALL_MEMORY_DEDUPE_ENABLED", true)
	c.MemoryDedupeSimilarityThr = r.num("NEORECALL_MEMORY_DEDUPE_SIMILARITY_THRESHOLD", 0.88, 0, 1)
	c.MemoryDedupeWindowMs = r.int64("NEORECALL_MEMORY_DEDUPE_WINDOW_MS", 6*60*60_000, 0, math.MaxInt64)
	c.MemoryDedupeMaxPairsPerRun = r.int("NEORECALL_MEMORY_DEDUPE_MAX_PAIRS_PER_RUN", 20, 0, 500)
	c.MemoryDedupeNeighbours = r.int("NEORECALL_MEMORY_DEDUPE_NEIGHBOURS", 5, 1, 50)
	c.AskMaxPerHour = r.int("NEORECALL_ASK_MAX_PER_HOUR", 240, 0, math.MaxInt)
	c.AskBurstPerMinute = r.int("NEORECALL_ASK_BURST_PER_MINUTE", 20, 0, math.MaxInt)

	c.AITokens4h = r.int("NEORECALL_AI_TOKENS_4H", 0, 0, math.MaxInt)
	c.AITokensWeekly = r.int("NEORECALL_AI_TOKENS_WEEKLY", 0, 0, math.MaxInt)
	c.TranscriptionSeconds4h = r.int("NEORECALL_TRANSCRIPTION_SECONDS_4H", 0, 0, math.MaxInt)
	c.TranscriptionSecondsWeekly = r.int("NEORECALL_TRANSCRIPTION_SECONDS_WEEKLY", 0, 0, math.MaxInt)

	c.SchedulerIntervalMs = r.int("NEORECALL_SCHEDULER_INTERVAL_MS", 60_000, 1_000, math.MaxInt)
	c.JobLeaseMs = r.int64("NEORECALL_JOB_LEASE_MS", 1_800_000, 10_000, math.MaxInt64)
	c.JobMaxAttempts = r.int("NEORECALL_JOB_MAX_ATTEMPTS", 5, 1, 100)
	c.DiagnosticRetentionDays = r.int("NEORECALL_DIAGNOSTIC_RETENTION_DAYS", 7, 1, 90)
	c.DiagnosticMaxEventsPerUser = r.int("NEORECALL_DIAGNOSTIC_MAX_EVENTS_PER_USER", 500, 50, 10_000)
	c.DiagnosticExportMaxEvents = r.int("NEORECALL_DIAGNOSTIC_EXPORT_MAX_EVENTS", 250, 10, 1_000)

	c.PlaudClientID = getenv("NEORECALL_PLAUD_CLIENT_ID")
	c.PlaudClientSecret = getenv("NEORECALL_PLAUD_CLIENT_SECRET")
	host := r.str("NEORECALL_PLAUD_API_HOST", "platform-us.plaud.ai")
	host = strings.TrimPrefix(host, "https://")
	host = strings.TrimPrefix(host, "http://")
	c.PlaudAPIHost = stripTrailingSlashes(host)

	if r.err != nil {
		return c, r.err
	}
	if err := Validate(c); err != nil {
		return c, err
	}
	return c, nil
}

// Validate runs cross-field consistency checks matching Node's server/config/validate.js.
func Validate(c Config) error {
	if c.SpeakerClusterContinuityThr > c.SpeakerClusterThreshold {
		return errors.New("NEORECALL_SPEAKER_CLUSTER_CONTINUITY_THRESHOLD must not exceed NEORECALL_SPEAKER_CLUSTER_THRESHOLD")
	}
	if c.ConversationSoftGapMs >= c.ConversationHardGapMs {
		return errors.New("NEORECALL_CONVERSATION_SOFT_GAP_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS")
	}
	if c.ConversationMinimumMs >= c.ConversationHardGapMs {
		return errors.New("NEORECALL_CONVERSATION_MINIMUM_MS must be shorter than NEORECALL_CONVERSATION_HARD_GAP_MS")
	}
	if c.ConversationQuietCloseMs < c.ConversationHardGapMs {
		return errors.New("NEORECALL_CONVERSATION_QUIET_CLOSE_MS must be at least NEORECALL_CONVERSATION_HARD_GAP_MS")
	}
	if c.ConversationMaximumMs <= c.ConversationMinimumMs {
		return errors.New("NEORECALL_CONVERSATION_MAXIMUM_MS must be longer than NEORECALL_CONVERSATION_MINIMUM_MS")
	}
	if c.ConversationMaximumCharacters > c.MaxConsolidationInputChars {
		return errors.New("NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS must not exceed NEORECALL_MAX_CONSOLIDATION_INPUT_CHARS")
	}
	if c.ConversationPreviewMinCharacters > c.ConversationMaximumCharacters {
		return errors.New("NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS must not exceed NEORECALL_CONVERSATION_MAXIMUM_CHARACTERS")
	}
	if c.MemoryOccasionGapMs < c.ConversationHardGapMs {
		return errors.New("NEORECALL_MEMORY_OCCASION_GAP_MS must be at least NEORECALL_CONVERSATION_HARD_GAP_MS")
	}
	if c.MemorySettleMs < c.ConversationHardGapMs {
		return errors.New("NEORECALL_MEMORY_SETTLE_MS must be at least NEORECALL_CONVERSATION_HARD_GAP_MS")
	}
	if c.MemoryOccasionMaxWaitMs <= c.MemorySettleMs {
		return errors.New("NEORECALL_MEMORY_OCCASION_MAX_WAIT_MS must be longer than NEORECALL_MEMORY_SETTLE_MS")
	}
	if c.AudioPreprocessTimeoutMs > c.TranscriptionTimeoutMs {
		return errors.New("NEORECALL_AUDIO_PREPROCESS_TIMEOUT_MS must not exceed TRANSCRIPTION_REQUEST_TIMEOUT_MS")
	}
	if c.AIConsolidationMaxOutTokens+LLMPromptReserveTokens >= c.LLMContextSize {
		return fmt.Errorf("AI_CONSOLIDATION_MAX_OUTPUT_TOKENS (%d) leaves no room for input inside LLM_CONTEXT_SIZE (%d)", c.AIConsolidationMaxOutTokens, c.LLMContextSize)
	}
	if c.AIPreviewMaxOutTokens+LLMPromptReserveTokens >= c.LLMContextSize {
		return fmt.Errorf("AI_PREVIEW_MAX_OUTPUT_TOKENS (%d) leaves no room for input inside LLM_CONTEXT_SIZE (%d)", c.AIPreviewMaxOutTokens, c.LLMContextSize)
	}
	return nil
}
