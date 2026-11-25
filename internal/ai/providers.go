package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/providers"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/google/uuid"
)

type ChatRequest struct {
	UserID         string
	Purpose        string
	Messages       []Message
	ResponseFormat any
	MaxTokens      int
}

type ChatResponse struct {
	Raw       json.RawMessage
	RequestID string
}

type ProviderClient struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	Providers *providers.Service
	Usage     *usage.Service
	HTTP      *http.Client
	Log       *slog.Logger
}

func (c *ProviderClient) cfg() config.Config {
	if c.Cfg != nil {
		return c.Cfg()
	}
	return config.Config{}
}

func (c *ProviderClient) httpClient() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return ssrf.NewClient(ssrf.Options{Timeout: 0}) // per-request context timeout used
}

func (c *ProviderClient) Ready(ctx context.Context) bool {
	if c.Providers == nil {
		return false
	}
	rt := c.Providers.ResolveWorkload(ctx, "llm")
	if rt.BaseURL == "" || rt.Model == "" {
		return false
	}
	if rt.RequiresAPIKey && !rt.APIKeyConfigured {
		return false
	}
	return true
}

func (c *ProviderClient) DescribeNotReady(ctx context.Context) string {
	return "Not fully configured: a base URL, a model, or an API key is still missing."
}

var (
	contextOverflowRe = regexp.MustCompile(`(?i)context[_ ]length|context window|maximum context|too many tokens|prompt is too long|exceeds the available context|reduce the length|input is too long|too long for`)
	schemaRejectedRe  = regexp.MustCompile(`(?i)grammar|json[_ ]?schema|response[_ ]?format|unsupported schema`)
)

func WireSchema(v any) any {
	switch x := v.(type) {
	case []any:
		out := make([]any, len(x))
		for i, item := range x {
			out[i] = WireSchema(item)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			if k == "maxLength" {
				continue
			}
			out[k] = WireSchema(val)
		}
		return out
	default:
		return v
	}
}

func WireResponseFormat(rf any) any {
	if rf == nil {
		return map[string]any{"type": "json_object"}
	}
	m, _ := rf.(map[string]any)
	if m == nil || m["type"] != "json_schema" {
		return rf
	}
	js, _ := m["json_schema"].(map[string]any)
	if js == nil || js["schema"] == nil {
		return rf
	}
	jsCopy := make(map[string]any, len(js))
	for k, v := range js {
		jsCopy[k] = v
	}
	jsCopy["schema"] = WireSchema(js["schema"])
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	out["json_schema"] = jsCopy
	return out
}

func openAIMessages(msgs []Message) []map[string]any {
	out := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		switch cnt := m.Content.(type) {
		case []ContentPart:
			parts := make([]any, 0, len(cnt))
			for _, p := range cnt {
				if p.Type == "input_image" {
					parts = append(parts, map[string]any{
						"type":      "image_url",
						"image_url": map[string]any{"url": fmt.Sprintf("data:%s;base64,%s", p.MediaType, p.Data)},
					})
				} else {
					parts = append(parts, map[string]any{"type": p.Type, "text": p.Text})
				}
			}
			out = append(out, map[string]any{"role": m.Role, "content": parts})
		default:
			out = append(out, map[string]any{"role": m.Role, "content": m.Content})
		}
	}
	return out
}

func containsImage(msgs []Message) bool {
	for _, m := range msgs {
		if parts, ok := m.Content.([]ContentPart); ok {
			for _, p := range parts {
				if p.Type == "input_image" {
					return true
				}
			}
		}
	}
	return false
}

func thinkingAlreadyDisabled(eb map[string]any) bool {
	if eb == nil {
		return false
	}
	ctk, _ := eb["chat_template_kwargs"].(map[string]any)
	if ctk == nil {
		return false
	}
	en, ok := ctk["enable_thinking"].(bool)
	return ok && !en
}

func (c *ProviderClient) ChatJSON(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	rt := c.Providers.ResolveWorkload(ctx, "llm")
	if rt.Protocol == "anthropic" {
		return c.sendAnthropic(ctx, rt, req)
	}
	resp, err := c.sendOpenAI(ctx, rt, req, rt.ExtraBody)
	if err == nil {
		return resp, nil
	}
	var ae *AIError
	if errors.As(err, &ae) && ae.Status == 400 && schemaRejectedRe.MatchString(ae.Message) && req.ResponseFormat != nil {
		if c.Log != nil {
			c.Log.Warn("Endpoint could not compile response schema; retrying plain JSON", "purpose", req.Purpose, "model", rt.Model)
		}
		plain := req
		plain.ResponseFormat = map[string]any{"type": "json_object"}
		return c.sendOpenAI(ctx, rt, plain, rt.ExtraBody)
	}
	if errors.As(err, &ae) && ae.Code == "AI_OUTPUT_TRUNCATED" && !thinkingAlreadyDisabled(rt.ExtraBody) {
		eb := make(map[string]any, len(rt.ExtraBody)+1)
		for k, v := range rt.ExtraBody {
			eb[k] = v
		}
		eb["chat_template_kwargs"] = map[string]any{"enable_thinking": false}
		resp2, err2 := c.sendOpenAI(ctx, rt, req, eb)
		if err2 == nil {
			return resp2, nil
		}
		var ae2 *AIError
		if errors.As(err2, &ae2) && ae2.Code == "AI_OUTPUT_TRUNCATED" {
			return ChatResponse{}, err2
		}
		return ChatResponse{}, err
	}
	return ChatResponse{}, err
}

func (c *ProviderClient) recordStart(ctx context.Context, id, userID, purpose, provider, model string) {
	now := timeutil.NowISO()
	var uid any
	if userID != "" {
		uid = userID
	}
	_, _ = c.DB.W.ExecContext(ctx, `INSERT INTO ai_requests (id, user_id, purpose, provider, model, state, reserved_at, sent_at)
		VALUES (?, ?, ?, ?, ?, 'sent', ?, ?)`, id, uid, purpose, provider, model, now, now)
}

func (c *ProviderClient) recordSuccess(ctx context.Context, id string, status int, provReqID string, promptTok, compTok *int) {
	_, _ = c.DB.W.ExecContext(ctx, `UPDATE ai_requests SET state='succeeded', http_status=?, provider_request_id=?,
		prompt_tokens=?, completion_tokens=?, completed_at=? WHERE id=?`,
		status, provReqID, promptTok, compTok, timeutil.NowISO(), id)
}

func (c *ProviderClient) recordFailure(ctx context.Context, id string, status int, code string) {
	var st any
	if status > 0 {
		st = status
	}
	_, _ = c.DB.W.ExecContext(ctx, `UPDATE ai_requests SET state='failed', http_status=?, error_code=?, completed_at=? WHERE id=?`,
		st, code, timeutil.NowISO(), id)
}

func (c *ProviderClient) MarkValidationFailed(ctx context.Context, requestID, code string) {
	if requestID == "" {
		return
	}
	_, _ = c.DB.W.ExecContext(ctx, `UPDATE ai_requests SET state='failed', error_code=? WHERE id=?`, code, requestID)
}

func (c *ProviderClient) sendOpenAI(ctx context.Context, rt providers.ResolvedWorkload, req ChatRequest, extraBody map[string]any) (ChatResponse, error) {
	if rt.BaseURL == "" {
		return ChatResponse{}, &AIError{Code: "AI_NOT_CONFIGURED", Message: "The language-model API base URL is not configured."}
	}
	if rt.Model == "" {
		return ChatResponse{}, &AIError{Code: "AI_MODEL_NOT_CONFIGURED", Message: "AI_API_MODEL is not configured."}
	}
	if req.UserID != "" && c.Usage != nil {
		_, release, err := c.Usage.Enforce(ctx, req.UserID, "ai", 0)
		if err != nil {
			return ChatResponse{}, err
		}
		defer release()
	}

	id := uuid.NewString()
	c.recordStart(ctx, id, req.UserID, req.Purpose, rt.Provider, rt.Model)
	fail := func(status int, code, msg string) (ChatResponse, error) {
		c.recordFailure(ctx, id, status, code)
		return ChatResponse{}, &AIError{Code: code, Status: status, RequestID: id, Message: msg}
	}

	cfg := c.cfg()
	body := map[string]any{
		"model":           rt.Model,
		"messages":        openAIMessages(req.Messages),
		"response_format": WireResponseFormat(req.ResponseFormat),
		"temperature":     cfg.LLMTemperature,
	}
	if req.MaxTokens > 0 {
		body["max_tokens"] = req.MaxTokens
	}
	for k, v := range extraBody {
		body[k] = v
	}
	jb, _ := json.Marshal(body)

	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, cfg.AITimeoutMs))*time.Millisecond)
	defer cancel()
	httpReq, err := http.NewRequestWithContext(tctx, http.MethodPost, rt.BaseURL+"/chat/completions", bytes.NewReader(jb))
	if err != nil {
		return fail(0, "AI_REQUEST_FAILED", err.Error())
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if rt.APIKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+rt.APIKey)
	}
	res, err := c.httpClient().Do(httpReq)
	if err != nil {
		if errors.Is(tctx.Err(), context.DeadlineExceeded) {
			return fail(0, "AI_TIMEOUT", "The language model timed out.")
		}
		return fail(0, "AI_REQUEST_FAILED", err.Error())
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))

	var payload map[string]any
	_ = json.Unmarshal(raw, &payload)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		detail := fmt.Sprintf("The AI endpoint returned HTTP %d.", res.StatusCode)
		var errCodeStr string
		if eObj, _ := payload["error"].(map[string]any); eObj != nil {
			if m, _ := eObj["message"].(string); m != "" {
				detail = m
			}
			errCodeStr, _ = eObj["code"].(string)
			if errCodeStr == "" {
				errCodeStr, _ = eObj["type"].(string)
			}
		}
		if containsImage(req.Messages) && (res.StatusCode == 400 || res.StatusCode == 413 || res.StatusCode == 415 || res.StatusCode == 422) {
			return fail(res.StatusCode, "AI_MEDIA_REJECTED", "The configured model rejected image input.")
		}
		if (res.StatusCode == 400 || res.StatusCode == 413 || res.StatusCode == 422) &&
			(strings.Contains(strings.ToLower(errCodeStr), "context_length_exceeded") ||
				strings.Contains(strings.ToLower(errCodeStr), "string_above_max_length") ||
				contextOverflowRe.MatchString(detail)) {
			return fail(res.StatusCode, "AI_CONTEXT_EXCEEDED", fmt.Sprintf("The request was longer than the model's context allows: %s Lower LLM_CONTEXT_SIZE to match the endpoint, or lower NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS.", detail))
		}
		return fail(res.StatusCode, "AI_HTTP_ERROR", detail)
	}

	if eObj, _ := payload["error"].(map[string]any); eObj != nil {
		msg, _ := eObj["message"].(string)
		if msg == "" {
			msg = "The AI endpoint reported a provider error."
		}
		return fail(res.StatusCode, "AI_PROVIDER_ERROR", msg)
	}
	choices, _ := payload["choices"].([]any)
	var choice map[string]any
	if len(choices) > 0 {
		choice, _ = choices[0].(map[string]any)
	}
	if ce, _ := choice["error"].(map[string]any); ce != nil {
		msg, _ := ce["message"].(string)
		if msg == "" {
			msg = "The AI endpoint reported a provider error."
		}
		return fail(res.StatusCode, "AI_PROVIDER_ERROR", msg)
	}
	if fr, _ := choice["finish_reason"].(string); fr == "length" {
		return fail(res.StatusCode, "AI_OUTPUT_TRUNCATED", "The AI endpoint stopped the completion at the token limit; the response is incomplete.")
	}
	msgMap, _ := choice["message"].(map[string]any)
	var contentText string
	switch ct := msgMap["content"].(type) {
	case string:
		contentText = ct
	case []any:
		var sb strings.Builder
		for _, p := range ct {
			if pm, _ := p.(map[string]any); pm != nil {
				if t, _ := pm["text"].(string); t != "" {
					sb.WriteString(t)
				}
			}
		}
		contentText = sb.String()
	default:
		return fail(res.StatusCode, "AI_EMPTY_RESPONSE", "The AI endpoint returned no message content.")
	}

	var parsedCheck any
	if err := json.Unmarshal([]byte(contentText), &parsedCheck); err != nil {
		return fail(res.StatusCode, "AI_SCHEMA_INVALID", "The AI endpoint returned invalid JSON.")
	}
	provReqID, _ := payload["id"].(string)
	var pt, ct *int
	if u, _ := payload["usage"].(map[string]any); u != nil {
		if v, ok := u["prompt_tokens"].(float64); ok {
			iv := int(v)
			pt = &iv
		}
		if v, ok := u["completion_tokens"].(float64); ok {
			iv := int(v)
			ct = &iv
		}
	}
	c.recordSuccess(ctx, id, res.StatusCode, provReqID, pt, ct)
	return ChatResponse{Raw: json.RawMessage(contentText), RequestID: id}, nil
}

func (c *ProviderClient) sendAnthropic(ctx context.Context, rt providers.ResolvedWorkload, req ChatRequest) (ChatResponse, error) {
	if rt.BaseURL == "" || rt.Model == "" || rt.APIKey == "" {
		return ChatResponse{}, &AIError{Code: "AI_NOT_CONFIGURED", Message: "Anthropic requires a base URL, model, and API key."}
	}
	if req.UserID != "" && c.Usage != nil {
		_, release, err := c.Usage.Enforce(ctx, req.UserID, "ai", 0)
		if err != nil {
			return ChatResponse{}, err
		}
		defer release()
	}

	id := uuid.NewString()
	c.recordStart(ctx, id, req.UserID, req.Purpose, rt.Provider, rt.Model)
	fail := func(status int, code, msg string) (ChatResponse, error) {
		c.recordFailure(ctx, id, status, code)
		return ChatResponse{}, &AIError{Code: code, Status: status, RequestID: id, Message: msg}
	}

	var sysParts []string
	var conv []map[string]any
	for _, m := range req.Messages {
		if m.Role == "system" {
			if s, _ := m.Content.(string); s != "" {
				sysParts = append(sysParts, s)
			}
			continue
		}
		role := "user"
		if m.Role == "assistant" {
			role = "assistant"
		}
		switch cnt := m.Content.(type) {
		case []ContentPart:
			parts := make([]any, 0, len(cnt))
			for _, p := range cnt {
				if p.Type == "input_image" {
					parts = append(parts, map[string]any{
						"type":   "image",
						"source": map[string]any{"type": "base64", "media_type": p.MediaType, "data": p.Data},
					})
				} else {
					parts = append(parts, map[string]any{"type": p.Type, "text": p.Text})
				}
			}
			conv = append(conv, map[string]any{"role": role, "content": parts})
		default:
			conv = append(conv, map[string]any{"role": role, "content": m.Content})
		}
	}
	if rf, _ := req.ResponseFormat.(map[string]any); rf != nil && rf["type"] == "json_schema" {
		if js, _ := rf["json_schema"].(map[string]any); js != nil && js["schema"] != nil {
			sb, _ := json.Marshal(js["schema"])
			sysParts = append(sysParts, "Return only JSON that conforms exactly to this JSON Schema:\n"+string(sb))
		}
	} else {
		sysParts = append(sysParts, "Return only a valid JSON object.")
	}

	cfg := c.cfg()
	maxTok := req.MaxTokens
	if maxTok <= 0 {
		maxTok = cfg.AIPreviewMaxOutTokens
	}
	jb, _ := json.Marshal(map[string]any{
		"model":       rt.Model,
		"system":      strings.Join(sysParts, "\n\n"),
		"messages":    conv,
		"max_tokens":  maxTok,
		"temperature": cfg.LLMTemperature,
	})

	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, cfg.AITimeoutMs))*time.Millisecond)
	defer cancel()
	httpReq, err := http.NewRequestWithContext(tctx, http.MethodPost, rt.BaseURL+"/messages", bytes.NewReader(jb))
	if err != nil {
		return fail(0, "AI_REQUEST_FAILED", err.Error())
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("x-api-key", rt.APIKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")
	res, err := c.httpClient().Do(httpReq)
	if err != nil {
		if errors.Is(tctx.Err(), context.DeadlineExceeded) {
			return fail(0, "AI_TIMEOUT", "The AI request timed out.")
		}
		return fail(0, "AI_REQUEST_FAILED", err.Error())
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	var payload map[string]any
	_ = json.Unmarshal(raw, &payload)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		if containsImage(req.Messages) && (res.StatusCode == 400 || res.StatusCode == 413 || res.StatusCode == 415 || res.StatusCode == 422) {
			return fail(res.StatusCode, "AI_MEDIA_REJECTED", "The configured model rejected image input.")
		}
		msg := fmt.Sprintf("Anthropic returned HTTP %d.", res.StatusCode)
		if eObj, _ := payload["error"].(map[string]any); eObj != nil {
			if m, _ := eObj["message"].(string); m != "" {
				msg = m
			}
		}
		return fail(res.StatusCode, "AI_HTTP_ERROR", msg)
	}
	if payload["error"] != nil {
		msg := "Anthropic reported a provider error."
		if eObj, _ := payload["error"].(map[string]any); eObj != nil {
			if m, _ := eObj["message"].(string); m != "" {
				msg = m
			}
		}
		return fail(res.StatusCode, "AI_PROVIDER_ERROR", msg)
	}
	if payload["stop_reason"] == "max_tokens" {
		return fail(res.StatusCode, "AI_OUTPUT_TRUNCATED", "Anthropic stopped the completion at the token limit; the response is incomplete.")
	}
	var text strings.Builder
	if arr, _ := payload["content"].([]any); arr != nil {
		for _, p := range arr {
			if pm, _ := p.(map[string]any); pm != nil && pm["type"] == "text" {
				if t, _ := pm["text"].(string); t != "" {
					text.WriteString(t)
				}
			}
		}
	}
	if text.Len() == 0 {
		return fail(res.StatusCode, "AI_EMPTY_RESPONSE", "Anthropic returned no message content.")
	}
	var parsedCheck any
	if err := json.Unmarshal([]byte(text.String()), &parsedCheck); err != nil {
		return fail(res.StatusCode, "AI_SCHEMA_INVALID", "Anthropic returned invalid JSON.")
	}
	provReqID, _ := payload["id"].(string)
	var pt, ct *int
	if u, _ := payload["usage"].(map[string]any); u != nil {
		if v, ok := u["input_tokens"].(float64); ok {
			iv := int(v)
			pt = &iv
		}
		if v, ok := u["output_tokens"].(float64); ok {
			iv := int(v)
			ct = &iv
		}
	}
	c.recordSuccess(ctx, id, res.StatusCode, provReqID, pt, ct)
	return ChatResponse{Raw: json.RawMessage(text.String()), RequestID: id}, nil
}
