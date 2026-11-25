package transcription

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
)

type RuntimeProviderConfig struct {
	Provider       string
	Protocol       string // openai, deepgram, assemblyai
	BaseURL        string
	Model          string
	APIKey         string
	Language       string
	ResponseFormat string
	RequiresAPIKey bool
	ModelOptional  bool
	NeoRouter      bool
}

type ProviderError struct {
	Code      string
	Status    int
	Message   string
	Retryable bool
}

func (e *ProviderError) Error() string { return e.Message }

type TranscribeInput struct {
	Filename                    string
	ChannelLayout               string
	Vocabulary                  []string
	VocabularyCorrectionEnabled bool
	Timeout                     time.Duration
	PollInterval                time.Duration
	VocabOpts                   VocabOptions
}

type Provider interface {
	Ready() bool
	NotReadyReason() string
	Metered() bool
	Transcribe(ctx context.Context, in TranscribeInput) ([]Segment, error)
}

type baseProvider struct {
	cfg    RuntimeProviderConfig
	client *http.Client
	fetch  func(ctx context.Context, in TranscribeInput) ([]Segment, error)
}

func (b *baseProvider) Metered() bool { return true }

func (b *baseProvider) NotReadyReason() string {
	return "Not fully configured: a base URL, a model, or an API key is still missing."
}

func (b *baseProvider) Transcribe(ctx context.Context, in TranscribeInput) ([]Segment, error) {
	segs, err := b.fetch(ctx, in)
	if err != nil {
		return nil, err
	}
	if in.VocabularyCorrectionEnabled && len(in.Vocabulary) > 0 {
		segs = CorrectSegments(segs, in.Vocabulary, in.VocabOpts)
	}
	return segs, nil
}

func NewProvider(rt RuntimeProviderConfig, httpClient *http.Client) (Provider, error) {
	if httpClient == nil {
		httpClient = ssrf.NewClient(ssrf.Options{Timeout: 120 * time.Second})
	}
	bp := &baseProvider{cfg: rt, client: httpClient}
	switch rt.Protocol {
	case "openai":
		bp.fetch = bp.fetchOpenAI
		return &openAIProvider{bp}, nil
	case "deepgram":
		bp.fetch = bp.fetchDeepgram
		return &deepgramProvider{bp}, nil
	case "assemblyai":
		bp.fetch = bp.fetchAssemblyAI
		return &assemblyAIProvider{bp}, nil
	default:
		return nil, fmt.Errorf("Unsupported TRANSCRIPTION_PROVIDER: %s", rt.Provider)
	}
}

type openAIProvider struct{ *baseProvider }

func (p *openAIProvider) Ready() bool {
	return p.cfg.BaseURL != "" && (p.cfg.ModelOptional || p.cfg.Model != "") && (!p.cfg.RequiresAPIKey || p.cfg.APIKey != "")
}

func TranscriptionEndpoint(baseURL string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	trimmed := strings.TrimRight(u.Path, "/")
	if strings.HasSuffix(trimmed, "/audio/transcriptions") {
		u.Path = trimmed
		return strings.TrimRight(u.String(), "/"), nil
	}
	u.Path = trimmed + "/audio/transcriptions"
	return u.String(), nil
}

func (b *baseProvider) fetchOpenAI(ctx context.Context, in TranscribeInput) ([]Segment, error) {
	if b.cfg.BaseURL == "" || (!b.cfg.ModelOptional && b.cfg.Model == "") {
		return nil, &ProviderError{Code: "TRANSCRIPTION_PROVIDER_NOT_CONFIGURED", Message: "The transcription endpoint is not fully configured."}
	}
	endpoint, err := TranscriptionEndpoint(b.cfg.BaseURL)
	if err != nil {
		return nil, err
	}
	audioBytes, err := os.ReadFile(in.Filename)
	if err != nil {
		return nil, err
	}
	ext := strings.ToLower(filepath.Ext(in.Filename))
	if ext == "" {
		ext = ".wav"
	}
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, err := mw.CreateFormFile("file", "chunk"+ext)
	if err != nil {
		return nil, err
	}
	_, _ = fw.Write(audioBytes)
	if b.cfg.Model != "" {
		_ = mw.WriteField("model", b.cfg.Model)
	}
	if b.cfg.Language != "" {
		_ = mw.WriteField("language", b.cfg.Language)
	}
	if len(in.Vocabulary) > 0 {
		_ = mw.WriteField("prompt", strings.Join(in.Vocabulary, ", "))
	}
	rf := b.cfg.ResponseFormat
	if rf == "" {
		rf = "verbose_json"
	}
	_ = mw.WriteField("response_format", rf)
	_ = mw.Close()

	tctx, cancel := withOptionalTimeout(ctx, in.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(tctx, http.MethodPost, endpoint, &body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if b.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+b.cfg.APIKey)
	}
	res, err := b.client.Do(req)
	if err != nil {
		if errors.Is(tctx.Err(), context.DeadlineExceeded) {
			return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The transcription request timed out."}
		}
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		msg := extractAPIErrorMessage(raw, fmt.Sprintf("Transcription endpoint returned HTTP %d.", res.StatusCode))
		return nil, &ProviderError{Code: "TRANSCRIPTION_HTTP_ERROR", Status: res.StatusCode, Message: msg}
	}
	return NormalizeOpenAISegments(raw)
}

func NormalizeOpenAISegments(raw []byte) ([]Segment, error) {
	var payload struct {
		Text     string  `json:"text"`
		Language string  `json:"language"`
		Duration float64 `json:"duration"`
		Segments []struct {
			Text       string   `json:"text"`
			Start      float64  `json:"start"`
			End        float64  `json:"end"`
			AvgLogprob *float64 `json:"avg_logprob"`
			Speaker    *int     `json:"speaker"`
		} `json:"segments"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, err
	}
	if len(payload.Segments) == 0 {
		return BuildSegments([]Segment{{
			Text:     payload.Text,
			Language: payload.Language,
			StartMs:  0,
			EndMs:    SecondsToMs(payload.Duration),
		}}), nil
	}
	out := make([]Segment, 0, len(payload.Segments))
	for _, s := range payload.Segments {
		end := s.End
		if end == 0 {
			end = s.Start
		}
		out = append(out, Segment{
			Text:               s.Text,
			Language:           payload.Language,
			StartMs:            SecondsToMs(s.Start),
			EndMs:              SecondsToMs(end),
			ASRConfidence:      s.AvgLogprob,
			DiarizationSpeaker: s.Speaker,
		})
	}
	return BuildSegments(out), nil
}

type deepgramProvider struct{ *baseProvider }

func (p *deepgramProvider) Ready() bool {
	return p.cfg.BaseURL != "" && p.cfg.Model != "" && p.cfg.APIKey != ""
}

var nova3Re = regexp.MustCompile(`(?i)^nova-3(?:$|-)`)

func (b *baseProvider) fetchDeepgram(ctx context.Context, in TranscribeInput) ([]Segment, error) {
	if b.cfg.BaseURL == "" || b.cfg.Model == "" || b.cfg.APIKey == "" {
		return nil, &ProviderError{Code: "TRANSCRIPTION_PROVIDER_NOT_CONFIGURED", Message: "Deepgram requires a base URL, model, and API key."}
	}
	u, err := url.Parse(strings.TrimRight(b.cfg.BaseURL, "/") + "/v1/listen")
	if err != nil {
		return nil, err
	}
	q := u.Query()
	q.Set("model", b.cfg.Model)
	q.Set("smart_format", "true")
	q.Set("utterances", "true")
	q.Set("detect_language", "true")
	vocabKey := "keywords"
	if nova3Re.MatchString(b.cfg.Model) {
		vocabKey = "keyterm"
	}
	for _, term := range in.Vocabulary {
		q.Add(vocabKey, term)
	}
	u.RawQuery = q.Encode()

	audioBytes, err := os.ReadFile(in.Filename)
	if err != nil {
		return nil, err
	}
	tctx, cancel := withOptionalTimeout(ctx, in.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(tctx, http.MethodPost, u.String(), bytes.NewReader(audioBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Token "+b.cfg.APIKey)
	req.Header.Set("Content-Type", "application/octet-stream")
	res, err := b.client.Do(req)
	if err != nil {
		if errors.Is(tctx.Err(), context.DeadlineExceeded) {
			return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The Deepgram transcription request timed out."}
		}
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		msg := extractAPIErrorMessage(raw, fmt.Sprintf("Deepgram returned HTTP %d.", res.StatusCode))
		return nil, &ProviderError{Code: "TRANSCRIPTION_HTTP_ERROR", Status: res.StatusCode, Message: msg}
	}
	return NormalizeDeepgramSegments(raw)
}

func NormalizeDeepgramSegments(raw []byte) ([]Segment, error) {
	var payload struct {
		Results struct {
			Utterances []struct {
				Transcript string   `json:"transcript"`
				Language   string   `json:"language"`
				Start      float64  `json:"start"`
				End        float64  `json:"end"`
				Confidence *float64 `json:"confidence"`
				Speaker    *int     `json:"speaker"`
			} `json:"utterances"`
			Channels []struct {
				DetectedLanguage string `json:"detected_language"`
				Alternatives     []struct {
					Transcript string   `json:"transcript"`
					Confidence *float64 `json:"confidence"`
					Languages  []string `json:"languages"`
					Words      []struct {
						Start float64 `json:"start"`
						End   float64 `json:"end"`
					} `json:"words"`
				} `json:"alternatives"`
			} `json:"channels"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, err
	}
	if len(payload.Results.Utterances) > 0 {
		out := make([]Segment, 0, len(payload.Results.Utterances))
		for _, u := range payload.Results.Utterances {
			end := u.End
			if end == 0 {
				end = u.Start
			}
			out = append(out, Segment{
				Text:               u.Transcript,
				Language:           u.Language,
				StartMs:            SecondsToMs(u.Start),
				EndMs:              SecondsToMs(end),
				ASRConfidence:      u.Confidence,
				DiarizationSpeaker: u.Speaker,
			})
		}
		return BuildSegments(out), nil
	}
	if len(payload.Results.Channels) == 0 || len(payload.Results.Channels[0].Alternatives) == 0 {
		return nil, nil
	}
	ch := payload.Results.Channels[0]
	alt := ch.Alternatives[0]
	lang := ch.DetectedLanguage
	if len(alt.Languages) > 0 && alt.Languages[0] != "" {
		lang = alt.Languages[0]
	}
	var start, end float64
	if len(alt.Words) > 0 {
		start = alt.Words[0].Start
		end = alt.Words[len(alt.Words)-1].End
		if end == 0 {
			end = start
		}
	}
	return BuildSegments([]Segment{{
		Text:          alt.Transcript,
		Language:      lang,
		StartMs:       SecondsToMs(start),
		EndMs:         SecondsToMs(end),
		ASRConfidence: alt.Confidence,
	}}), nil
}

type assemblyAIProvider struct{ *baseProvider }

func (p *assemblyAIProvider) Ready() bool {
	return p.cfg.BaseURL != "" && p.cfg.APIKey != ""
}

func (b *baseProvider) fetchAssemblyAI(ctx context.Context, in TranscribeInput) ([]Segment, error) {
	if b.cfg.BaseURL == "" || b.cfg.APIKey == "" {
		return nil, &ProviderError{Code: "TRANSCRIPTION_PROVIDER_NOT_CONFIGURED", Message: "AssemblyAI requires a base URL and API key."}
	}
	timeout := in.Timeout
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	pollInt := in.PollInterval
	if pollInt <= 0 {
		pollInt = time.Second
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	audioBytes, err := os.ReadFile(in.Filename)
	if err != nil {
		return nil, err
	}
	base := strings.TrimRight(b.cfg.BaseURL, "/")
	doJSON := func(method, targetURL string, contentType string, body io.Reader) ([]byte, error) {
		if tctx.Err() != nil {
			return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The AssemblyAI transcription request timed out."}
		}
		req, err := http.NewRequestWithContext(tctx, method, targetURL, body)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", b.cfg.APIKey)
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		res, err := b.client.Do(req)
		if err != nil {
			if errors.Is(tctx.Err(), context.DeadlineExceeded) {
				return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The AssemblyAI transcription request timed out."}
			}
			return nil, err
		}
		defer res.Body.Close()
		raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			msg := extractAPIErrorMessage(raw, fmt.Sprintf("AssemblyAI returned HTTP %d.", res.StatusCode))
			return nil, &ProviderError{Code: "TRANSCRIPTION_HTTP_ERROR", Status: res.StatusCode, Message: msg}
		}
		return raw, nil
	}

	upRaw, err := doJSON(http.MethodPost, base+"/v2/upload", "application/octet-stream", bytes.NewReader(audioBytes))
	if err != nil {
		return nil, err
	}
	var up struct {
		UploadURL string `json:"upload_url"`
	}
	_ = json.Unmarshal(upRaw, &up)

	reqBody := map[string]any{"audio_url": up.UploadURL}
	if b.cfg.Model != "" {
		reqBody["speech_models"] = []string{b.cfg.Model}
	}
	if len(in.Vocabulary) > 0 {
		reqBody["keyterms_prompt"] = in.Vocabulary
	}
	jb, _ := json.Marshal(reqBody)
	subRaw, err := doJSON(http.MethodPost, base+"/v2/transcript", "application/json", bytes.NewReader(jb))
	if err != nil {
		return nil, err
	}
	type assemblyResp struct {
		ID           string   `json:"id"`
		Status       string   `json:"status"`
		Error        string   `json:"error"`
		Text         string   `json:"text"`
		LanguageCode string   `json:"language_code"`
		Confidence   *float64 `json:"confidence"`
		Utterances   []struct {
			Text       string   `json:"text"`
			Start      int      `json:"start"`
			End        int      `json:"end"`
			Confidence *float64 `json:"confidence"`
			Speaker    *int     `json:"speaker"`
		} `json:"utterances"`
		Words []struct {
			Start int `json:"start"`
			End   int `json:"end"`
		} `json:"words"`
	}
	var cur assemblyResp
	_ = json.Unmarshal(subRaw, &cur)
	for cur.Status != "completed" && cur.Status != "error" {
		dl, _ := tctx.Deadline()
		wait := pollInt
		if rem := time.Until(dl); rem <= 0 {
			return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The AssemblyAI transcription request timed out."}
		} else if rem < wait {
			wait = rem
		}
		timer := time.NewTimer(wait)
		select {
		case <-tctx.Done():
			timer.Stop()
			return nil, &ProviderError{Code: "TRANSCRIPTION_TIMEOUT", Message: "The AssemblyAI transcription request timed out."}
		case <-timer.C:
		}
		pollRaw, err := doJSON(http.MethodGet, base+"/v2/transcript/"+cur.ID, "", nil)
		if err != nil {
			return nil, err
		}
		cur = assemblyResp{}
		_ = json.Unmarshal(pollRaw, &cur)
	}
	if cur.Status == "error" {
		msg := cur.Error
		if msg == "" {
			msg = "AssemblyAI could not transcribe the audio."
		}
		return nil, &ProviderError{Code: "TRANSCRIPTION_PROVIDER_ERROR", Message: msg, Retryable: false}
	}
	if len(cur.Utterances) > 0 {
		out := make([]Segment, 0, len(cur.Utterances))
		for _, u := range cur.Utterances {
			end := u.End
			if end == 0 {
				end = u.Start
			}
			out = append(out, Segment{
				Text:               u.Text,
				Language:           cur.LanguageCode,
				StartMs:            u.Start,
				EndMs:              end,
				ASRConfidence:      u.Confidence,
				DiarizationSpeaker: u.Speaker,
			})
		}
		return BuildSegments(out), nil
	}
	var start, end int
	if len(cur.Words) > 0 {
		start = cur.Words[0].Start
		end = cur.Words[len(cur.Words)-1].End
		if end == 0 {
			end = start
		}
	}
	return BuildSegments([]Segment{{
		Text:          cur.Text,
		Language:      cur.LanguageCode,
		StartMs:       start,
		EndMs:         end,
		ASRConfidence: cur.Confidence,
	}}), nil
}

func withOptionalTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if d <= 0 {
		return context.WithCancel(ctx)
	}
	return context.WithTimeout(ctx, d)
}

func extractAPIErrorMessage(raw []byte, fallback string) string {
	var body struct {
		Error any    `json:"error"`
		ErrMg string `json:"err_msg"`
	}
	if json.Unmarshal(raw, &body) == nil {
		if body.ErrMg != "" {
			return body.ErrMg
		}
		switch v := body.Error.(type) {
		case string:
			if v != "" {
				return v
			}
		case map[string]any:
			if m, _ := v["message"].(string); m != "" {
				return m
			}
		}
	}
	return fallback
}
