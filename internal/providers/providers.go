package providers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/llm/transport"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/neorouter"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

type ProviderDefinition struct {
	ID             string
	Label          string
	Protocol       string
	BaseURL        string
	DefaultModel   string
	ResponseFormat string
	KeyEnvironment []string
	RequiresAPIKey bool
	ModelOptional  bool
	NeoRouter      bool
}

var (
	LLMOrder = []string{
		"openai", "anthropic", "google", "groq", "mistral",
		"xai", "deepseek", "openrouter", "together", "openai_compatible", "neorouter",
	}
	LLMProviders = map[string]ProviderDefinition{
		"openai":            {ID: "openai", Label: "OpenAI", Protocol: "openai", BaseURL: "https://api.openai.com/v1", KeyEnvironment: []string{"OPENAI_API_KEY"}, RequiresAPIKey: true},
		"anthropic":         {ID: "anthropic", Label: "Anthropic", Protocol: "anthropic", BaseURL: "https://api.anthropic.com/v1", KeyEnvironment: []string{"ANTHROPIC_API_KEY"}, RequiresAPIKey: true},
		"google":            {ID: "google", Label: "Google Gemini", Protocol: "openai", BaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", KeyEnvironment: []string{"GEMINI_API_KEY", "GOOGLE_API_KEY"}, RequiresAPIKey: true},
		"groq":              {ID: "groq", Label: "Groq", Protocol: "openai", BaseURL: "https://api.groq.com/openai/v1", KeyEnvironment: []string{"GROQ_API_KEY"}, RequiresAPIKey: true},
		"mistral":           {ID: "mistral", Label: "Mistral AI", Protocol: "openai", BaseURL: "https://api.mistral.ai/v1", KeyEnvironment: []string{"MISTRAL_API_KEY"}, RequiresAPIKey: true},
		"xai":               {ID: "xai", Label: "xAI (Grok)", Protocol: "openai", BaseURL: "https://api.x.ai/v1", KeyEnvironment: []string{"XAI_API_KEY"}, RequiresAPIKey: true},
		"deepseek":          {ID: "deepseek", Label: "DeepSeek", Protocol: "openai", BaseURL: "https://api.deepseek.com/v1", KeyEnvironment: []string{"DEEPSEEK_API_KEY"}, RequiresAPIKey: true},
		"openrouter":        {ID: "openrouter", Label: "OpenRouter", Protocol: "openai", BaseURL: "https://openrouter.ai/api/v1", KeyEnvironment: []string{"OPENROUTER_API_KEY"}, RequiresAPIKey: true},
		"together":          {ID: "together", Label: "Together AI", Protocol: "openai", BaseURL: "https://api.together.xyz/v1", KeyEnvironment: []string{"TOGETHER_API_KEY"}, RequiresAPIKey: true},
		"openai_compatible": {ID: "openai_compatible", Label: "Custom OpenAI-compatible", Protocol: "openai", KeyEnvironment: []string{"AI_API_KEY"}},
		"neorouter":         {ID: "neorouter", Label: "NeoRouter", Protocol: "openai", DefaultModel: "auto", RequiresAPIKey: true, NeoRouter: true},
	}

	TranscriptionOrder = []string{
		"openai", "groq", "deepgram", "assemblyai", "openai-compatible", "neorouter",
	}
	TranscriptionProviders = map[string]ProviderDefinition{
		"openai":            {ID: "openai", Label: "OpenAI", Protocol: "openai", BaseURL: "https://api.openai.com/v1", ResponseFormat: "json", KeyEnvironment: []string{"OPENAI_API_KEY"}, RequiresAPIKey: true},
		"groq":              {ID: "groq", Label: "Groq", Protocol: "openai", BaseURL: "https://api.groq.com/openai/v1", ResponseFormat: "verbose_json", KeyEnvironment: []string{"GROQ_API_KEY"}, RequiresAPIKey: true},
		"deepgram":          {ID: "deepgram", Label: "Deepgram", Protocol: "deepgram", BaseURL: "https://api.deepgram.com", KeyEnvironment: []string{"DEEPGRAM_API_KEY"}, RequiresAPIKey: true},
		"assemblyai":        {ID: "assemblyai", Label: "AssemblyAI", Protocol: "assemblyai", BaseURL: "https://api.assemblyai.com", ModelOptional: true, KeyEnvironment: []string{"ASSEMBLYAI_API_KEY"}, RequiresAPIKey: true},
		"openai-compatible": {ID: "openai-compatible", Label: "Custom OpenAI-compatible", Protocol: "openai", ModelOptional: true, KeyEnvironment: []string{"TRANSCRIPTION_API_KEY"}},
		"neorouter":         {ID: "neorouter", Label: "NeoRouter", Protocol: "openai", DefaultModel: "auto", ResponseFormat: "verbose_json", RequiresAPIKey: true, NeoRouter: true},
	}
)

const (
	keyLLM                 = "providers.llm"
	keyLLMSecret           = "providers.llm.api_key"
	keyTranscription       = "providers.transcription"
	keyTranscriptionSecret = "providers.transcription.api_key"
)

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	NeoRouter *neorouter.Service
	HTTP      *http.Client
	Getenv    func(string) string
	ProbePath string
	Log       *slog.Logger

	// Hooked by ai & transcription runtime in main/app wiring:
	TestLLMFn             func(ctx context.Context) map[string]any
	TestSpeakerIdentityFn func() map[string]any
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) getenv(k string) string {
	if s.Getenv != nil {
		return s.Getenv(k)
	}
	return os.Getenv(k)
}

func (s *Service) httpClient() *http.Client {
	if s.HTTP != nil {
		return s.HTTP
	}
	return ssrf.NewClient(ssrf.Options{Timeout: 30 * time.Second})
}

func withoutTrailingSlash(v string) string {
	return strings.TrimRight(v, "/")
}

func settingKeyFor(workload string) string {
	if workload == "llm" {
		return keyLLM
	}
	return keyTranscription
}

func secretKeyFor(workload, provider string) string {
	if workload == "llm" {
		return keyLLMSecret + "." + provider
	}
	return keyTranscriptionSecret + "." + provider
}

func (s *Service) readJSONSetting(ctx context.Context, key string) map[string]any {
	if s.DB == nil {
		return nil
	}
	var raw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM app_settings WHERE key=?`, key).Scan(&raw); err != nil {
		return nil
	}
	var m map[string]any
	_ = json.Unmarshal([]byte(raw), &m)
	return m
}

func (s *Service) readEncryptedSecret(ctx context.Context, key string) string {
	if s.DB == nil {
		return ""
	}
	var raw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM app_settings WHERE key=?`, key).Scan(&raw); err != nil {
		return ""
	}
	var enc string
	if json.Unmarshal([]byte(raw), &enc) != nil || enc == "" {
		return ""
	}
	mk, err := s.MasterKey()
	if err != nil {
		return ""
	}
	plain, err := crypto.DecryptString(mk, enc)
	if err != nil {
		return ""
	}
	return plain
}

func sourceOf(hasAdmin, hasEnv, hasDefault bool) string {
	if hasAdmin {
		return "admin"
	}
	if hasEnv {
		return "environment"
	}
	if hasDefault {
		return "default"
	}
	return "none"
}

type ResolvedWorkload struct {
	Provider                    string         `json:"provider"`
	Label                       string         `json:"label"`
	Protocol                    string         `json:"protocol"`
	Model                       string         `json:"model"`
	BaseURL                     string         `json:"baseUrl"`
	APIKey                      string         `json:"-"`
	Language                    *string        `json:"language"`
	ResponseFormat              *string        `json:"responseFormat"`
	ExtraBody                   map[string]any `json:"extraBody"`
	APIKeyConfigured            bool           `json:"apiKeyConfigured"`
	APIKeySource                string         `json:"apiKeySource"`
	EnvironmentAPIKeyConfigured bool           `json:"environmentApiKeyConfigured"`
	Sources                     map[string]any `json:"sources"`
	RequiresAPIKey              bool           `json:"-"`
	ModelOptional               bool           `json:"-"`
	NeoRouter                   bool           `json:"-"`
}

func (s *Service) ResolveWorkload(ctx context.Context, workload string) ResolvedWorkload {
	c := s.cfg()
	isLLM := workload == "llm"
	catalog := TranscriptionProviders
	fallbackProv := "openai-compatible"
	envProv := c.TranscriptionProvider
	envModel := c.TranscriptionAPIModel
	envBaseURL := c.TranscriptionAPIBaseURL
	envKey := c.TranscriptionAPIKey
	if isLLM {
		catalog = LLMProviders
		fallbackProv = "openai_compatible"
		envProv = c.AIProvider
		envModel = c.AIAPIModel
		envBaseURL = c.AIAPIBaseURL
		envKey = c.AIAPIKey
	}

	saved := s.readJSONSetting(ctx, settingKeyFor(workload))
	overrideProv, _ := saved["provider"].(string)
	if overrideProv != "" {
		if _, ok := catalog[overrideProv]; !ok {
			saved = nil
			overrideProv = ""
		}
	}

	prov := overrideProv
	if prov == "" {
		prov = envProv
	}
	if prov == "" {
		prov = fallbackProv
	}
	def := catalog[prov]

	adminModel, hasAdminModel := saved["model"].(string)
	model := adminModel
	if !hasAdminModel || model == "" {
		if envModel != "" {
			model = envModel
		} else {
			model = def.DefaultModel
		}
	}

	adminBase, hasAdminBase := saved["baseUrl"].(string)
	baseURL := adminBase
	if !hasAdminBase || baseURL == "" {
		if envBaseURL != "" {
			baseURL = envBaseURL
		} else {
			baseURL = def.BaseURL
		}
	}
	baseURL = withoutTrailingSlash(baseURL)

	adminAPIKey := s.readEncryptedSecret(ctx, secretKeyFor(workload, prov))
	var provEnvKey string
	for _, kn := range def.KeyEnvironment {
		if v := strings.TrimSpace(s.getenv(kn)); v != "" {
			provEnvKey = v
			break
		}
	}
	envAPIKey := envKey
	if envAPIKey == "" {
		envAPIKey = provEnvKey
	}
	apiKey := adminAPIKey
	if apiKey == "" {
		apiKey = envAPIKey
	}

	var langPtr *string
	var respFmtPtr *string
	var extraBody map[string]any
	sources := map[string]any{
		"provider": sourceOf(overrideProv != "", envProv != "", true),
		"model":    sourceOf(hasAdminModel && adminModel != "", envModel != "", def.DefaultModel != ""),
		"baseUrl":  sourceOf(hasAdminBase && adminBase != "", envBaseURL != "", def.BaseURL != ""),
	}

	if isLLM {
		if eb, ok := saved["extraBody"].(map[string]any); ok {
			extraBody = eb
		} else if c.AIAPIExtraBody != nil {
			extraBody = c.AIAPIExtraBody
		}
		sources["extraBody"] = sourceOf(saved["extraBody"] != nil, c.AIAPIExtraBody != nil, false)
	} else {
		if al, ok := saved["language"].(string); ok && al != "" {
			langPtr = &al
		} else if c.TranscriptionAPILanguage != "" {
			cp := c.TranscriptionAPILanguage
			langPtr = &cp
		}
		rf := "verbose_json"
		if arf, ok := saved["responseFormat"].(string); ok && arf != "" {
			rf = arf
		} else if c.TranscriptionAPIResponseFormat != "" {
			rf = c.TranscriptionAPIResponseFormat
		} else if def.ResponseFormat != "" {
			rf = def.ResponseFormat
		}
		respFmtPtr = &rf
		sources["language"] = sourceOf(saved["language"] != nil, c.TranscriptionAPILanguage != "", false)
		sources["responseFormat"] = sourceOf(saved["responseFormat"] != nil, c.TranscriptionAPIResponseFormat != "", true)
	}

	var nrConn *neorouter.Connection
	if def.NeoRouter && s.NeoRouter != nil {
		nrConn, _ = s.NeoRouter.Get(ctx)
		if nrConn != nil {
			baseURL = nrConn.APIBase
			apiKey = nrConn.APIKey
		} else {
			baseURL = ""
			apiKey = ""
		}
	}

	apiKeySrc := "none"
	apiKeyConfigured := apiKey != ""
	envKeyConfigured := envAPIKey != ""
	if def.NeoRouter {
		apiKeyConfigured = nrConn != nil
		envKeyConfigured = false
	} else if adminAPIKey != "" {
		apiKeySrc = "admin"
	} else if envAPIKey != "" {
		apiKeySrc = "environment"
	}

	return ResolvedWorkload{
		Provider:                    prov,
		Label:                       def.Label,
		Protocol:                    def.Protocol,
		Model:                       model,
		BaseURL:                     baseURL,
		APIKey:                      apiKey,
		Language:                    langPtr,
		ResponseFormat:              respFmtPtr,
		ExtraBody:                   extraBody,
		APIKeyConfigured:            apiKeyConfigured,
		APIKeySource:                apiKeySrc,
		EnvironmentAPIKeyConfigured: envKeyConfigured,
		Sources:                     sources,
		RequiresAPIKey:              def.RequiresAPIKey,
		ModelOptional:               def.ModelOptional,
		NeoRouter:                   def.NeoRouter,
	}
}

func (s *Service) IsNeoRouter(ctx context.Context, workload string) bool {
	return s.ResolveWorkload(ctx, workload).Provider == neorouter.ProviderID
}

func (s *Service) SetNeoRouter(ctx context.Context, workload string) error {
	_, err := s.Update(ctx, map[string]WorkloadUpdate{
		workload: {Provider: neorouter.ProviderID, Model: strPtr("auto")},
	})
	return err
}

func (s *Service) ClearOverride(ctx context.Context, workload string) error {
	_, err := s.DB.W.ExecContext(ctx, `DELETE FROM app_settings WHERE key=?`, settingKeyFor(workload))
	return err
}

func strPtr(s string) *string { return &s }

type WorkloadUpdate struct {
	Provider       string         `json:"provider"`
	Model          *string        `json:"model"`
	BaseURL        *string        `json:"baseUrl"`
	APIKey         string         `json:"apiKey"`
	ClearAPIKey    bool           `json:"clearApiKey"`
	Language       *string        `json:"language"`
	ResponseFormat *string        `json:"responseFormat"`
	ExtraBody      map[string]any `json:"extraBody"`
}

func catalogForAdmin(order []string, cat map[string]ProviderDefinition) []map[string]any {
	out := make([]map[string]any, 0, len(order))
	for _, id := range order {
		d := cat[id]
		var defBase any
		if d.BaseURL != "" {
			defBase = d.BaseURL
		}
		var defModel any
		if d.DefaultModel != "" {
			defModel = d.DefaultModel
		}
		rf := d.ResponseFormat
		if rf == "" {
			rf = "verbose_json"
		}
		out = append(out, map[string]any{
			"id":                    d.ID,
			"label":                 d.Label,
			"protocol":              d.Protocol,
			"defaultBaseUrl":        defBase,
			"defaultModel":          defModel,
			"defaultResponseFormat": rf,
			"apiKeyRequired":        d.RequiresAPIKey,
			"modelOptional":         d.ModelOptional,
			"neorouter":             d.NeoRouter,
		})
	}
	return out
}

func (s *Service) GetAdmin(ctx context.Context) map[string]any {
	return map[string]any{
		"llm":           s.ResolveWorkload(ctx, "llm"),
		"transcription": s.ResolveWorkload(ctx, "transcription"),
		"catalogs": map[string]any{
			"llm":           catalogForAdmin(LLMOrder, LLMProviders),
			"transcription": catalogForAdmin(TranscriptionOrder, TranscriptionProviders),
		},
	}
}

func (s *Service) Update(ctx context.Context, input map[string]WorkloadUpdate) (map[string]any, error) {
	if len(input) == 0 {
		return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "At least one provider setting must be supplied.")
	}
	for wl, val := range input {
		if wl != "llm" && wl != "transcription" {
			return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Unknown workload: "+wl)
		}
		cat := TranscriptionProviders
		if wl == "llm" {
			cat = LLMProviders
		}
		def, ok := cat[val.Provider]
		if !ok {
			return nil, httperr.New(http.StatusBadRequest, "UNSUPPORTED_PROVIDER", fmt.Sprintf("Unsupported %s provider: %s.", wl, val.Provider))
		}
		if !def.ModelOptional && (val.Model == nil || strings.TrimSpace(*val.Model) == "") && def.DefaultModel == "" {
			return nil, httperr.New(http.StatusBadRequest, "PROVIDER_MODEL_REQUIRED", fmt.Sprintf("A model is required for %s.", def.Label))
		}
		if def.NeoRouter && s.NeoRouter != nil {
			if c, _ := s.NeoRouter.Get(ctx); c == nil {
				return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_NOT_CONNECTED", "NeoRouter is not connected. Connect it first.")
			}
		}
		if !def.NeoRouter && (val.BaseURL == nil || strings.TrimSpace(*val.BaseURL) == "") && def.BaseURL == "" {
			return nil, httperr.New(http.StatusBadRequest, "PROVIDER_BASE_URL_REQUIRED", fmt.Sprintf("A base URL is required for %s.", def.Label))
		}
		if val.BaseURL != nil && strings.TrimSpace(*val.BaseURL) != "" {
			u, err := url.Parse(strings.TrimSpace(*val.BaseURL))
			if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
				return nil, httperr.New(http.StatusBadRequest, "INVALID_PROVIDER_URL", "Provider base URLs must use HTTP or HTTPS.")
			}
		}
	}

	mk, err := s.MasterKey()
	if err != nil {
		return nil, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	upsert := `INSERT INTO app_settings (key, value_json) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`

	for wl, val := range input {
		cat := TranscriptionProviders
		if wl == "llm" {
			cat = LLMProviders
		}
		def := cat[val.Provider]
		stored := map[string]any{
			"provider": val.Provider,
			"model":    nil,
			"baseUrl":  nil,
		}
		if val.Model != nil && strings.TrimSpace(*val.Model) != "" {
			stored["model"] = strings.TrimSpace(*val.Model)
		} else if def.DefaultModel != "" {
			stored["model"] = def.DefaultModel
		}
		if !def.NeoRouter {
			if val.BaseURL != nil && strings.TrimSpace(*val.BaseURL) != "" {
				stored["baseUrl"] = withoutTrailingSlash(strings.TrimSpace(*val.BaseURL))
			} else if def.BaseURL != "" {
				stored["baseUrl"] = def.BaseURL
			}
		}
		if wl == "transcription" {
			stored["language"] = val.Language
			stored["responseFormat"] = val.ResponseFormat
		} else {
			stored["extraBody"] = val.ExtraBody
		}
		jb, _ := json.Marshal(stored)
		if _, err := tx.ExecContext(ctx, upsert, settingKeyFor(wl), string(jb)); err != nil {
			return nil, err
		}
		if def.NeoRouter {
			continue
		}
		sk := secretKeyFor(wl, val.Provider)
		if val.ClearAPIKey {
			if _, err := tx.ExecContext(ctx, `DELETE FROM app_settings WHERE key=?`, sk); err != nil {
				return nil, err
			}
		} else if strings.TrimSpace(val.APIKey) != "" {
			enc, err := crypto.EncryptString(mk, strings.TrimSpace(val.APIKey))
			if err != nil {
				return nil, err
			}
			eb, _ := json.Marshal(enc)
			if _, err := tx.ExecContext(ctx, upsert, sk, string(eb)); err != nil {
				return nil, err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.GetAdmin(ctx), nil
}

func (s *Service) ClearOverrides(ctx context.Context) (map[string]any, error) {
	if _, err := s.DB.W.ExecContext(ctx, `DELETE FROM app_settings
		WHERE key IN (?, ?) OR key LIKE ? OR key LIKE ? OR key IN (?, ?)`,
		keyLLM, keyTranscription, keyLLMSecret+".%", keyTranscriptionSecret+".%", keyLLMSecret, keyTranscriptionSecret); err != nil {
		return nil, err
	}
	return s.GetAdmin(ctx), nil
}

func (s *Service) DiscoverModels(ctx context.Context, workload, provider, baseURL, apiKey string) (map[string]any, error) {
	if workload != "llm" && workload != "transcription" {
		return nil, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid workload.")
	}
	cat := TranscriptionProviders
	if workload == "llm" {
		cat = LLMProviders
	}
	def, ok := cat[provider]
	if !ok {
		return nil, httperr.New(http.StatusBadRequest, "UNSUPPORTED_PROVIDER", fmt.Sprintf("Unsupported %s provider: %s.", workload, provider))
	}
	if def.NeoRouter && s.NeoRouter != nil {
		conn, _ := s.NeoRouter.Get(ctx)
		if conn == nil {
			return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_NOT_CONNECTED", "NeoRouter is not connected. Connect it first.")
		}
		typ := "transcription"
		if workload == "llm" {
			typ = "chat"
		}
		list, err := s.NeoRouter.ModelList(ctx, conn, typ)
		if err != nil {
			return nil, httperr.New(http.StatusBadGateway, "NEOROUTER_UNAVAILABLE", err.Error())
		}
		var auto, nonAuto []string
		for _, id := range list.Models {
			if neorouter.IsAutoModel(id) {
				auto = append(auto, id)
			} else {
				nonAuto = append(nonAuto, id)
			}
		}
		sort.Strings(nonAuto)
		models := append(auto, nonAuto...)
		if models == nil {
			models = []string{}
		}
		return map[string]any{"models": models, "automatic": false, "modelOptional": false}, nil
	}
	if def.Protocol == "assemblyai" {
		return map[string]any{"models": []string{}, "automatic": true}, nil
	}

	cur := s.ResolveWorkload(ctx, workload)
	effBase := withoutTrailingSlash(strings.TrimSpace(baseURL))
	if effBase == "" && cur.Provider == provider {
		effBase = cur.BaseURL
	}
	if effBase == "" {
		effBase = def.BaseURL
	}
	effKey := strings.TrimSpace(apiKey)
	if effKey == "" {
		effKey = s.readEncryptedSecret(ctx, secretKeyFor(workload, provider))
	}
	if effKey == "" && cur.Provider == provider {
		effKey = cur.APIKey
	}
	if effKey == "" {
		if workload == "llm" {
			effKey = s.cfg().AIAPIKey
		} else {
			effKey = s.cfg().TranscriptionAPIKey
		}
	}
	if effKey == "" {
		for _, kn := range def.KeyEnvironment {
			if v := strings.TrimSpace(s.getenv(kn)); v != "" {
				effKey = v
				break
			}
		}
	}

	if effBase == "" {
		return nil, httperr.New(http.StatusBadRequest, "PROVIDER_BASE_URL_REQUIRED", "A provider base URL is required to discover models.")
	}
	if def.RequiresAPIKey && effKey == "" {
		return nil, httperr.New(http.StatusBadRequest, "PROVIDER_API_KEY_REQUIRED", fmt.Sprintf("An API key is required to discover %s models.", def.Label))
	}

	catalogURL := effBase + "/v1/models"
	if def.Protocol != "deepgram" {
		u, err := url.Parse(effBase)
		if err != nil {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_PROVIDER_URL", "Invalid provider URL.")
		}
		p := strings.TrimRight(u.Path, "/")
		p = strings.TrimSuffix(p, "/audio/transcriptions")
		u.Path = p + "/models"
		catalogURL = u.String()
	}

	hdrs := map[string]string{}
	switch def.Protocol {
	case "anthropic":
		hdrs["x-api-key"] = effKey
		hdrs["anthropic-version"] = "2023-06-01"
	case "deepgram":
		if effKey != "" {
			hdrs["Authorization"] = "Token " + effKey
		}
	default:
		if effKey != "" {
			hdrs["Authorization"] = "Bearer " + effKey
		}
	}
	res, err := transport.FetchText(ctx, s.httpClient(), transport.FetchOptions{
		Method:   http.MethodGet,
		URL:      catalogURL,
		Header:   hdrs,
		MaxBytes: 4 << 20,
		Service:  def.Label,
		Timeout:  30 * time.Second,
		Provider: provider,
	})
	if err != nil {
		return nil, httperr.New(http.StatusBadGateway, "MODEL_DISCOVERY_FAILED", fmt.Sprintf("Could not reach %s: %v", catalogURL, err))
	}
	var payload map[string]any
	_ = json.Unmarshal([]byte(res.Text), &payload)
	if !res.OK() {
		opt := " Type the model name yourself if the service does not list them."
		if def.ModelOptional {
			opt = " This provider does not require a model, so you can leave the field empty."
		}
		if res.Status == 404 || res.Status == 405 || res.Status == 501 {
			return nil, httperr.New(http.StatusBadGateway, "MODEL_DISCOVERY_UNSUPPORTED", fmt.Sprintf("%s does not offer a model list at %s.%s", def.Label, catalogURL, opt))
		}
		return nil, httperr.New(http.StatusBadGateway, "MODEL_DISCOVERY_FAILED", fmt.Sprintf("%s returned HTTP %d from %s.%s", def.Label, res.Status, catalogURL, opt))
	}

	var rawList []any
	if def.Protocol == "deepgram" {
		rawList, _ = payload["stt"].([]any)
	} else {
		if d, _ := payload["data"].([]any); len(d) > 0 {
			rawList = d
		} else {
			rawList, _ = payload["models"].([]any)
		}
	}
	seen := make(map[string]bool)
	var models []string
	for _, entry := range rawList {
		var id string
		switch e := entry.(type) {
		case string:
			id = e
		case map[string]any:
			if def.Protocol == "deepgram" {
				for _, k := range []string{"canonical_name", "name", "uuid"} {
					if v, _ := e[k].(string); v != "" {
						id = v
						break
					}
				}
			} else {
				for _, k := range []string{"id", "name", "model"} {
					if v, _ := e[k].(string); v != "" {
						id = v
						break
					}
				}
			}
		}
		id = strings.TrimSpace(id)
		if id != "" && !seen[id] {
			seen[id] = true
			models = append(models, id)
		}
	}
	sort.Strings(models)
	if models == nil {
		models = []string{}
	}
	return map[string]any{"models": models, "automatic": false, "modelOptional": def.ModelOptional}, nil
}

func (s *Service) TranscriptionProvider(ctx context.Context) (transcription.Provider, error) {
	rt := s.ResolveWorkload(ctx, "transcription")
	lang := ""
	if rt.Language != nil {
		lang = *rt.Language
	}
	rf := "verbose_json"
	if rt.ResponseFormat != nil {
		rf = *rt.ResponseFormat
	}
	return transcription.NewProvider(transcription.RuntimeProviderConfig{
		Provider:       rt.Provider,
		Protocol:       rt.Protocol,
		BaseURL:        rt.BaseURL,
		Model:          rt.Model,
		APIKey:         rt.APIKey,
		Language:       lang,
		ResponseFormat: rf,
		RequiresAPIKey: rt.RequiresAPIKey,
		ModelOptional:  rt.ModelOptional,
		NeoRouter:      rt.NeoRouter,
	}, s.httpClient())
}

func (s *Service) TestTranscription(ctx context.Context) map[string]any {
	rt := s.ResolveWorkload(ctx, "transcription")
	started := time.Now()
	probe := s.ProbePath
	if probe == "" {
		probe = filepath.Join("test", "fixtures", "de_en_two_speakers.wav")
	}
	if _, err := os.Stat(probe); err != nil {
		return map[string]any{"ok": false, "provider": rt.Provider, "error": "The bundled sample recording is missing from this installation."}
	}
	prov, err := s.TranscriptionProvider(ctx)
	if err != nil {
		return map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "error": err.Error()}
	}
	if !prov.Ready() {
		return map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "error": prov.NotReadyReason()}
	}
	c := s.cfg()
	segs, err := prov.Transcribe(ctx, transcription.TranscribeInput{
		Filename:      probe,
		ChannelLayout: "mono",
		Timeout:       time.Duration(max(1000, c.TranscriptionTimeoutMs)) * time.Millisecond,
		PollInterval:  time.Duration(max(100, c.TranscriptionPollIntervalMs)) * time.Millisecond,
	})
	ms := time.Since(started).Milliseconds()
	if err != nil {
		var code any
		var pe *transcription.ProviderError
		if errors.As(err, &pe) {
			code = pe.Code
		}
		return map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "ms": ms, "error": err.Error(), "code": code}
	}
	if len(segs) == 0 {
		return map[string]any{
			"ok": false, "provider": rt.Provider, "model": rt.Model, "ms": ms,
			"error": "The service answered but returned no speech for a recording that contains it. Check the model and language settings.",
		}
	}
	var parts []string
	for _, seg := range segs {
		parts = append(parts, seg.Text)
	}
	summary := strings.TrimSpace(strings.Join(parts, " "))
	if len(summary) > 240 {
		summary = summary[:239] + "…"
	}
	return map[string]any{"ok": true, "provider": rt.Provider, "model": rt.Model, "ms": ms, "segments": len(segs), "text": summary}
}

func (s *Service) TestProviders(ctx context.Context) map[string]any {
	tRes := s.TestTranscription(ctx)
	var llmRes, spkRes map[string]any
	if s.TestLLMFn != nil {
		llmRes = s.TestLLMFn(ctx)
	} else {
		rt := s.ResolveWorkload(ctx, "llm")
		llmRes = map[string]any{"ok": false, "provider": rt.Provider, "model": rt.Model, "error": "LLM engine not initialized."}
	}
	if s.TestSpeakerIdentityFn != nil {
		spkRes = s.TestSpeakerIdentityFn()
	} else {
		spkRes = map[string]any{"ok": false, "error": "Not installed on this platform; transcripts will have no speaker labels. Run `neorecall setup`."}
	}
	return map[string]any{
		"transcription":   tRes,
		"speakerIdentity": spkRes,
		"llm":             llmRes,
	}
}

func (s *Service) DescribeForLog(ctx context.Context) map[string]any {
	desc := func(wl ResolvedWorkload) map[string]any {
		var cred any = false
		if wl.APIKeyConfigured {
			cred = wl.APIKeySource
		}
		return map[string]any{
			"provider":             wl.Provider,
			"model":                wl.Model,
			"endpoint":             wl.BaseURL,
			"credentialConfigured": cred,
		}
	}
	return map[string]any{
		"languageModel": desc(s.ResolveWorkload(ctx, "llm")),
		"speech":        desc(s.ResolveWorkload(ctx, "transcription")),
	}
}
