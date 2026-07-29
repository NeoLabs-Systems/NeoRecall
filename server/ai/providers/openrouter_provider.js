'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

function extractContent(payload) {
  const content = payload?.choices?.[0]?.message?.content;
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
