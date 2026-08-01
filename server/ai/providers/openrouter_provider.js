'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

function extractContent(payload) {
  // A model that ran out of completion budget still answers 200 with a
  // perfectly ordinary-looking body whose JSON simply stops mid-string. Read as
  // a parse error that is indistinguishable from a model that cannot follow the
  // contract, and the remedy — more budget — is the one thing nobody would try.
  // Reasoning models make this the common case rather than the rare one: their
  // internal tokens are billed as completion tokens and count against the same
  // limit, so most of the budget can be gone before the answer starts.
  // OpenRouter can answer HTTP 200 and still carry a failure: a provider error
  // in the payload or on the choice itself. Without this check that surfaces as
  // "no message content", which hides the actual reason from the operator.
  const embedded = payload?.error || payload?.choices?.[0]?.error;
  if (embedded) {
    throw Object.assign(new Error(embedded.message || 'OpenRouter reported a provider error.'), {
      code: 'AI_PROVIDER_ERROR',
      providerCode: embedded.code ?? null,
    });
  }
  const choice = payload?.choices?.[0];
  if (choice?.finish_reason === 'length') {
    const usage = payload.usage || {};
    throw Object.assign(new Error('OpenRouter stopped the completion at the token limit; the response is incomplete.'), {
      code: 'AI_OUTPUT_TRUNCATED',
      completionTokens: usage.completion_tokens ?? null,
      reasoningTokens: usage.completion_tokens_details?.reasoning_tokens ?? null,
    });
  }
  const content = choice?.message?.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((part) => part.text || '').join('');
  throw Object.assign(new Error('OpenRouter returned no message content.'), { code: 'AI_EMPTY_RESPONSE' });
}

async function chatJSON({ userId, purpose, messages, model, responseFormat = null, maxTokens = null }) {
  const config = getConfig();
  if (!config.openRouterApiKey) throw Object.assign(new Error('OPENROUTER_API_KEY is not configured.'), { code: 'AI_NOT_CONFIGURED' });
  if (!model) throw Object.assign(new Error('AI_DEFAULT_MODEL is not configured.'), { code: 'AI_MODEL_NOT_CONFIGURED' });
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const db = getDatabase();
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at,sent_at)
    VALUES (?,?,?,'openrouter',?,'sent',?,?)`).run(id, userId, purpose, model, now, now);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.aiTimeoutMs);
  try {
    const response = await fetch(`${config.openRouterBaseUrl}/chat/completions`, {
      method: 'POST', signal: controller.signal,
      headers: {
        Authorization: `Bearer ${config.openRouterApiKey}`, 'Content-Type': 'application/json',
        ...(config.publicUrl ? { 'HTTP-Referer': config.publicUrl } : {}), 'X-Title': 'NeoRecall',
      },
      body: JSON.stringify({
        model, messages, response_format: responseFormat || { type: 'json_object' },
        ...(maxTokens ? { max_tokens: maxTokens } : {}),
        ...(responseFormat?.type === 'json_schema' ? { provider: { require_parameters: true } } : {}),
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(payload?.error?.message || `OpenRouter returned HTTP ${response.status}.`);
      error.code = 'AI_HTTP_ERROR'; error.status = response.status; throw error;
    }
    const parsed = JSON.parse(extractContent(payload));
    const usage = payload.usage || {};
    db.prepare(`UPDATE ai_requests SET state='succeeded',http_status=?,provider_request_id=?,prompt_tokens=?,completion_tokens=?,cost_usd=?,completed_at=? WHERE id=?`)
      .run(response.status, payload.id || null, usage.prompt_tokens ?? null, usage.completion_tokens ?? null, usage.cost ?? null, new Date().toISOString(), id);
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

module.exports = { chatJSON };
