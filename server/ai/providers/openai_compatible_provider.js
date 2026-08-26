'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const https = require('node:https');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('language-model');

// Structured generation against the operator's OpenAI-compatible endpoint.
// There is deliberately no in-process fallback: the endpoint may be a hosted
// API or a service on another machine.

function ready() {
  const settings = providerSettings.getRuntime().llm;
  return settings.protocol === 'openai' && Boolean(settings.baseUrl && settings.model)
    && (!providerSettings.LLM_PROVIDERS[settings.provider].requiresApiKey || settings.apiKeyConfigured);
}

function extractContent(payload) {
  // A 200 can still carry a failure two ways: an error embedded in the payload,
  // and a completion that hit the token limit and simply stops mid-JSON. Both
  // otherwise surface as an unexplained parse error or "no message content",
  // hiding the one remedy that works — more budget, or a narrower window.
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

// Wording that means "the prompt did not fit", which no status code
// distinguishes from a transient fault. Every vendor words it differently, so
// the message is what has to be read. Recognised, it becomes
// AI_CONTEXT_EXCEEDED, which narrows the batch and eventually quarantines the
// conversation — otherwise an oversized conversation is retried as transient
// forever and never produces a memory.
const CONTEXT_OVERFLOW = /context[_ ]length|context window|maximum context|too many tokens|prompt is too long|exceeds the available context|reduce the length|input is too long|too long for/i;

function contextOverflow(status, payload, message) {
  if (![400, 413, 422].includes(status)) return false;
  const code = String(payload?.error?.code || payload?.error?.type || '');
  return /context_length_exceeded|string_above_max_length/i.test(code) || CONTEXT_OVERFLOW.test(String(message || ''));
}

// Strips `maxLength` before sending. Servers that compile a JSON schema into a
// sampling grammar (llama.cpp and everything on it) unroll `maxLength: 2000`
// into 2000 repetitions of a character rule and reject the request with
// "failed to parse grammar", naming no field. Measured: the summary field alone
// breaks it. Costs nothing to drop — the response schema still checks every
// length after generation and trims overlong prose.
function wireSchema(schema) {
  if (Array.isArray(schema)) return schema.map(wireSchema);
  if (!schema || typeof schema !== 'object') return schema;
  return Object.fromEntries(Object.entries(schema)
    .filter(([key]) => key !== 'maxLength')
    .map(([key, value]) => [key, wireSchema(value)]));
}

function wireResponseFormat(responseFormat) {
  if (responseFormat?.type !== 'json_schema' || !responseFormat.json_schema?.schema) return responseFormat;
  return {
    ...responseFormat,
    json_schema: { ...responseFormat.json_schema, schema: wireSchema(responseFormat.json_schema.schema) },
  };
}

function openAiMessages(messages) {
  return messages.map((message) => !Array.isArray(message.content) ? message : ({
    ...message,
    content: message.content.map((part) => part.type === 'input_image'
      ? { type: 'image_url', image_url: { url: `data:${part.mediaType};base64,${part.data}` } }
      : part),
  }));
}

function containsImage(messages) {
  return messages.some((message) => Array.isArray(message.content)
    && message.content.some((part) => part.type === 'input_image'));
}

// Asks a model not to deliberate before answering. Not standardised, so it is
// never sent unprompted: a strict API rejects body fields it does not
// recognise. Sent only after a real truncation, and only if the operator has
// not already set the field.
const NO_THINKING = Object.freeze({ chat_template_kwargs: { enable_thinking: false } });

function thinkingAlreadyDisabled(extraBody) {
  return extraBody?.chat_template_kwargs?.enable_thinking === false;
}

// Whether the endpoint refused the shape we asked for rather than the request.
// Grammar converters do not all cover the same keywords, and their errors name
// no field — so the response is to retry without a schema rather than guess
// which keyword this build dislikes.
function schemaRejected(status, message) {
  return status === 400 && /grammar|json[_ ]?schema|response[_ ]?format|unsupported schema/i.test(String(message || ''));
}

async function chatJSON(request) {
  const settings = providerSettings.getRuntime().llm;
  try {
    return await sendChat(request, settings.extraBody || null);
  } catch (error) {
    // A schema is an optimisation, not the contract: the prompt states the shape
    // and the response is validated here regardless, so plain JSON gets the same
    // guarantees by a slower road.
    if (schemaRejected(error.status, error.message) && request.responseFormat) {
      logger.warn('The endpoint could not compile the response schema; asking for plain JSON instead', {
        purpose: request.purpose, model: settings.model, endpoint: settings.baseUrl,
        reason: String(error.message || '').slice(0, 300),
      });
      return sendChat({ ...request, responseFormat: { type: 'json_object' } }, settings.extraBody || null);
    }
    // Truncation on a reasoning model is worth one retry without deliberation:
    // consolidation otherwise blames the input, narrows the batch, and
    // quarantines the conversation. If the retry fails too, report the original
    // truncation — that is the fault worth fixing.
    if (error.code !== 'AI_OUTPUT_TRUNCATED' || thinkingAlreadyDisabled(settings.extraBody)) throw error;
    try {
      return await sendChat(request, { ...(settings.extraBody || {}), ...NO_THINKING });
    } catch (retryError) {
      throw retryError.code === 'AI_OUTPUT_TRUNCATED' ? retryError : error;
    }
  }
}

// One JSON POST on the configured deadline. Not `fetch`: it abandons a request
// whose response headers have not arrived in five minutes and reports only
// "fetch failed", and a local model can legitimately need longer. This deadline
// is an inactivity timeout, so a model answering steadily is never cut off.
function postJson(url, { headers, body, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const transport = target.protocol === 'https:' ? https : http;
    const request = transport.request(target, { method: 'POST', headers }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let payload = {};
        try { payload = text ? JSON.parse(text) : {}; } catch { payload = {}; }
        resolve({ status: response.statusCode, ok: response.statusCode >= 200 && response.statusCode < 300, payload });
      });
    });
    request.setTimeout(timeoutMs, () => {
      request.destroy(Object.assign(
        new Error(`The model sent nothing for ${Math.round(timeoutMs / 1000)} seconds.`),
        { code: 'AI_TIMEOUT' },
      ));
    });
    request.on('error', reject);
    request.end(body);
  });
}

async function sendChat({ userId, purpose, messages, responseFormat = null, maxTokens = null }, extraBody) {
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
  const startedAt = Date.now();
  try {
    const response = await postJson(`${settings.baseUrl}/chat/completions`, {
      headers: {
        'Content-Type': 'application/json',
        ...(settings.apiKey ? { Authorization: `Bearer ${settings.apiKey}` } : {}),
      },
      body: JSON.stringify({
        model, messages: openAiMessages(messages), response_format: wireResponseFormat(responseFormat) || { type: 'json_object' },
        ...(maxTokens ? { max_tokens: maxTokens } : {}),
        ...(extraBody || {}),
      }),
      timeoutMs: config.aiTimeoutMs,
    });
    const { payload } = response;
    if (!response.ok) {
      const detail = payload?.error?.message || `The AI endpoint returned HTTP ${response.status}.`;
      if (containsImage(messages) && [400, 413, 415, 422].includes(response.status)) {
        throw Object.assign(new Error('The configured model rejected image input.'), {
          code: 'AI_MEDIA_REJECTED', status: response.status,
        });
      }
      if (contextOverflow(response.status, payload, detail)) {
        throw Object.assign(new Error(`The request was longer than the model's context allows: ${detail} Lower LLM_CONTEXT_SIZE to match the endpoint, or lower NEORECALL_CONSOLIDATION_WINDOW_CHARACTERS.`), {
          code: 'AI_CONTEXT_EXCEEDED', status: response.status,
        });
      }
      const error = new Error(detail);
      error.code = 'AI_HTTP_ERROR'; error.status = response.status; throw error;
    }
    const parsed = JSON.parse(extractContent(payload));
    const usage = payload.usage || {};
    db.prepare(`UPDATE ai_requests SET state='succeeded',http_status=?,provider_request_id=?,prompt_tokens=?,completion_tokens=?,completed_at=? WHERE id=?`)
      .run(response.status, payload.id || null, usage.prompt_tokens ?? null, usage.completion_tokens ?? null, new Date().toISOString(), id);
    logger.debug('Language-model request succeeded', {
      requestId: id, purpose, model, seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
      promptTokens: usage.prompt_tokens ?? null, completionTokens: usage.completion_tokens ?? null,
    });
    return { value: parsed, requestId: id };
  } catch (error) {
    const code = error.name === 'AbortError' ? 'AI_TIMEOUT' : error.code || 'AI_REQUEST_FAILED';
    db.prepare(`UPDATE ai_requests SET state='failed',http_status=?,error_code=?,completed_at=? WHERE id=?`)
      .run(error.status || null, code, new Date().toISOString(), id);
    // Names the cause without opening the database: endpoint, model, wording.
    logger.warn('Language-model request failed', {
      requestId: id, purpose, model, provider: settings.provider, endpoint: settings.baseUrl,
      errorCode: code, httpStatus: error.status || null,
      seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
      reason: String(error.message || '').slice(0, 400),
    });
    error.code = code;
    error.aiRequestId = id;
    throw error;
  }
}

module.exports = { chatJSON, ready, contextOverflow, schemaRejected, wireSchema, wireResponseFormat, openAiMessages, NO_THINKING };
