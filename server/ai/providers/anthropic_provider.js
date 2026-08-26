'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');

function ready() {
  const settings = providerSettings.getRuntime().llm;
  return settings.protocol === 'anthropic' && Boolean(settings.baseUrl && settings.model && settings.apiKey);
}

function responseText(payload) {
  if (payload?.error) {
    throw Object.assign(new Error(payload.error.message || 'Anthropic reported a provider error.'), {
      code: 'AI_PROVIDER_ERROR',
      providerCode: payload.error.type || null,
    });
  }
  if (payload?.stop_reason === 'max_tokens') {
    throw Object.assign(new Error('Anthropic stopped the completion at the token limit; the response is incomplete.'), {
      code: 'AI_OUTPUT_TRUNCATED',
      completionTokens: payload.usage?.output_tokens ?? null,
    });
  }
  const text = Array.isArray(payload?.content)
    ? payload.content.filter((part) => part.type === 'text').map((part) => part.text || '').join('')
    : '';
  if (!text) throw Object.assign(new Error('Anthropic returned no message content.'), { code: 'AI_EMPTY_RESPONSE' });
  return text;
}

function anthropicMessages(messages, responseFormat) {
  const system = messages.filter((message) => message.role === 'system').map((message) => message.content).join('\n\n');
  const conversation = messages.filter((message) => message.role !== 'system').map((message) => ({
    role: message.role === 'assistant' ? 'assistant' : 'user',
    content: Array.isArray(message.content) ? message.content.map((part) => part.type === 'input_image'
      ? { type: 'image', source: { type: 'base64', media_type: part.mediaType, data: part.data } }
      : part) : message.content,
  }));
  const schema = responseFormat?.type === 'json_schema' ? responseFormat.json_schema?.schema : null;
  const schemaInstruction = schema
    ? `Return only JSON that conforms exactly to this JSON Schema:\n${JSON.stringify(schema)}`
    : 'Return only a valid JSON object.';
  return { system: [system, schemaInstruction].filter(Boolean).join('\n\n'), messages: conversation };
}

async function chatJSON({ userId, purpose, messages, responseFormat = null, maxTokens = null }) {
  const config = getConfig();
  const settings = providerSettings.getRuntime().llm;
  if (!settings.baseUrl || !settings.model || !settings.apiKey) {
    throw Object.assign(new Error('Anthropic requires a base URL, model, and API key.'), { code: 'AI_NOT_CONFIGURED' });
  }
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const db = getDatabase();
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at,sent_at)
    VALUES (?,?,?,?,?,'sent',?,?)`).run(id, userId, purpose, settings.provider, settings.model, now, now);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.aiTimeoutMs);
  try {
    const converted = anthropicMessages(messages, responseFormat);
    const response = await fetch(`${settings.baseUrl}/messages`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': settings.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: settings.model,
        system: converted.system,
        messages: converted.messages,
        max_tokens: maxTokens || config.aiPreviewMaxOutputTokens,
        temperature: config.llmTemperature,
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const hasImage = messages.some((message) => Array.isArray(message.content)
        && message.content.some((part) => part.type === 'input_image'));
      if (hasImage && [400, 413, 415, 422].includes(response.status)) {
        const error = new Error('The configured model rejected image input.');
        error.code = 'AI_MEDIA_REJECTED'; error.status = response.status; throw error;
      }
      const error = new Error(payload?.error?.message || `Anthropic returned HTTP ${response.status}.`);
      error.code = 'AI_HTTP_ERROR'; error.status = response.status; throw error;
    }
    const parsed = JSON.parse(responseText(payload));
    db.prepare(`UPDATE ai_requests SET state='succeeded',http_status=?,provider_request_id=?,prompt_tokens=?,completion_tokens=?,completed_at=? WHERE id=?`)
      .run(response.status, payload.id || null, payload.usage?.input_tokens ?? null, payload.usage?.output_tokens ?? null, new Date().toISOString(), id);
    return { value: parsed, requestId: id };
  } catch (error) {
    const code = error.name === 'AbortError' ? 'AI_TIMEOUT' : error.code || 'AI_REQUEST_FAILED';
    db.prepare(`UPDATE ai_requests SET state='failed',http_status=?,error_code=?,completed_at=? WHERE id=?`)
      .run(error.status || null, code, new Date().toISOString(), id);
    error.code = code;
    error.aiRequestId = id;
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { chatJSON, ready, responseText, anthropicMessages };
