'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

/// Sends structured generation requests to the OpenAI-compatible endpoint the
/// operator configured. NeoRecall deliberately has no in-process generation
/// fallback: the endpoint can be a hosted API or a separately deployed service
/// on another machine.

function ready() {
  const settings = providerSettings.getRuntime().llm;
  return settings.protocol === 'openai' && Boolean(settings.baseUrl && settings.model)
    && (!providerSettings.LLM_PROVIDERS[settings.provider].requiresApiKey || settings.apiKeyConfigured);
}

function extractContent(payload) {
  // A model that ran out of completion budget still answers 200 with a
  // perfectly ordinary-looking body whose JSON simply stops mid-string. Read as
  // a parse error that is indistinguishable from a model that cannot follow the
  // contract, and the remedy — more budget, or a narrower window — is the one
  // thing nobody would try. Reasoning models make this the common case rather
  // than the rare one: their internal tokens are billed as completion tokens and
  // count against the same limit, so most of the budget can be gone before the
  // answer starts.
  //
  // A gateway can also answer HTTP 200 and still carry a failure: an error in
  // the payload or on the choice itself. Without this check that surfaces as
  // "no message content", which hides the actual reason from the operator.
  const embedded = payload?.error || payload?.choices?.[0]?.error;
  if (embedded) {
    throw Object.assign(new Error(embedded.message || 'The AI endpoint reported a provider error.'), {
      code: 'AI_PROVIDER_ERROR',
      providerCode: embedded.code ?? null,
    });
  }
  const choice = payload?.choices?.[0];
  if (choice?.finish_reason === 'length') {
    const usage = payload.usage || {};
    const completionTokens = usage.completion_tokens ?? null;
    const reasoningTokens = usage.completion_tokens_details?.reasoning_tokens ?? null;
    const spent = reasoningTokens
      ? ` It spent ${reasoningTokens} of ${completionTokens} tokens reasoning before answering.`
      : completionTokens ? ` It used all ${completionTokens} tokens it was allowed.` : '';
    throw Object.assign(new Error(`The AI endpoint stopped the completion at the token limit; the response is incomplete.${spent}`), {
      code: 'AI_OUTPUT_TRUNCATED',
      completionTokens,
      reasoningTokens,
    });
  }
  const content = choice?.message?.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((part) => part.text || '').join('');
  throw Object.assign(new Error('The AI endpoint returned no message content.'), { code: 'AI_EMPTY_RESPONSE' });
}

async function chatJSON({ userId, purpose, messages, responseFormat = null, maxTokens = null }) {
  const config = getConfig();
  const settings = providerSettings.getRuntime().llm;
  if (!settings.baseUrl) throw Object.assign(new Error('The language-model API base URL is not configured.'), { code: 'AI_NOT_CONFIGURED' });
  const model = settings.model;
  if (!model) throw Object.assign(new Error('AI_API_MODEL is not configured.'), { code: 'AI_MODEL_NOT_CONFIGURED' });
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const db = getDatabase();
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at,sent_at)
    VALUES (?,?,?,?,?,'sent',?,?)`).run(id, userId, purpose, settings.provider, model, now, now);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.aiTimeoutMs);
  try {
    const response = await fetch(`${settings.baseUrl}/chat/completions`, {
      method: 'POST', signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        ...(settings.apiKey ? { Authorization: `Bearer ${settings.apiKey}` } : {}),
      },
      body: JSON.stringify({
        model, messages, response_format: responseFormat || { type: 'json_object' },
        ...(maxTokens ? { max_tokens: maxTokens } : {}),
        ...(settings.extraBody || {}),
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(payload?.error?.message || `The AI endpoint returned HTTP ${response.status}.`);
      error.code = 'AI_HTTP_ERROR'; error.status = response.status; throw error;
    }
    const parsed = JSON.parse(extractContent(payload));
    const usage = payload.usage || {};
    db.prepare(`UPDATE ai_requests SET state='succeeded',http_status=?,provider_request_id=?,prompt_tokens=?,completion_tokens=?,completed_at=? WHERE id=?`)
      .run(response.status, payload.id || null, usage.prompt_tokens ?? null, usage.completion_tokens ?? null, new Date().toISOString(), id);
    return { value: parsed, requestId: id };
  } catch (error) {
    const code = error.name === 'AbortError' ? 'AI_TIMEOUT' : error.code || 'AI_REQUEST_FAILED';
    db.prepare(`UPDATE ai_requests SET state='failed',http_status=?,error_code=?,completed_at=? WHERE id=?`)
      .run(error.status || null, code, new Date().toISOString(), id);
    error.code = code;
    error.aiRequestId = id;
    throw error;
  } finally { clearTimeout(timer); }
}

module.exports = { chatJSON, ready };
