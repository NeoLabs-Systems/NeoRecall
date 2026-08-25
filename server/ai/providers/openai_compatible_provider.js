'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const providerSettings = require('../../services/settings/provider_settings_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('language-model');

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

/// The request field that asks a model not to deliberate before answering.
///
/// Not standardised, which is why NeoRecall never sends it unprompted — a strict
/// API rejects body fields it does not recognise, and breaking every request to
/// pre-empt a problem the provider may not have would be a poor trade.
/// Whether a rejection means the prompt did not fit, rather than something a
/// retry could fix.
///
/// It matters which, because the two are handled in opposite ways. A transport
/// fault is worth retrying; a prompt that is too long produces the identical
/// rejection every time, and the pipeline treats it as transient — so an
/// oversized conversation is retried, fails the run without being narrowed or
/// quarantined, re-enters the candidate set on the next scheduler tick, and does
/// it all again. Forever, without ever producing a memory.
///
/// That is not hypothetical: NeoRecall windows its input against LLM_CONTEXT_SIZE,
/// which is a claim about somebody else's server. Set it larger than the endpoint
/// really allows and every consolidation overflows.
///
/// No status code says this and every vendor words it differently, so the wording
/// is what has to be read. Recognised, it becomes AI_CONTEXT_EXCEEDED, which
/// narrows the batch and eventually quarantines the conversation rather than
/// looping on it.
const CONTEXT_OVERFLOW = /context[_ ]length|context window|maximum context|too many tokens|prompt is too long|exceeds the available context|reduce the length|input is too long|too long for/i;

function contextOverflow(status, payload, message) {
  if (![400, 413, 422].includes(status)) return false;
  const code = String(payload?.error?.code || payload?.error?.type || '');
  return /context_length_exceeded|string_above_max_length/i.test(code) || CONTEXT_OVERFLOW.test(String(message || ''));
}

/// Length bounds a schema-to-grammar converter cannot express cheaply.
///
/// Servers that enforce a JSON schema by compiling it into a sampling grammar —
/// llama.cpp, and everything built on it — expand `maxLength: 2000` into two
/// thousand unrolled repetitions of a character rule. The grammar becomes too
/// large to compile and the whole request is rejected with "failed to parse
/// grammar", which says nothing about which field caused it. Measured directly
/// against that converter: the summary field alone is enough to break it.
///
/// Dropping the bound on the wire costs nothing, because it was never the thing
/// enforcing it. The response schema still checks every length after generation,
/// and prose that comes back too long is trimmed rather than rejected — so the
/// guarantee is unchanged and only the impossible instruction is gone. Hosted
/// APIs that do not compile grammars are unaffected either way.
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

const NO_THINKING = Object.freeze({ chat_template_kwargs: { enable_thinking: false } });

function thinkingAlreadyDisabled(extraBody) {
  return extraBody?.chat_template_kwargs?.enable_thinking === false;
}

/// Whether the endpoint refused the *shape* we asked for rather than the request.
///
/// Servers that enforce a JSON schema compile it into a sampling grammar, and
/// their converters do not all cover the same keywords. One rejected a schema
/// with "Failed to initialize samplers: failed to parse grammar" — a message
/// that names no field, so there is nothing to correct even when you can read
/// it. Guessing which keyword a given build dislikes is a losing game: the next
/// server will dislike a different one.
function schemaRejected(status, message) {
  return status === 400 && /grammar|json[_ ]?schema|response[_ ]?format|unsupported schema/i.test(String(message || ''));
}

async function chatJSON(request) {
  const settings = providerSettings.getRuntime().llm;
  try {
    return await sendChat(request, settings.extraBody || null);
  } catch (error) {
    // Asking for a schema is an optimisation, not the contract. The prompt spells
    // out the shape it wants in full, and the response is validated and trimmed
    // here whatever the endpoint promised — so when a server cannot compile the
    // schema, asking for plain JSON instead gets exactly the same guarantees by a
    // slower road. Refusing to work at all because a server's grammar converter
    // is limited would be the wrong answer, and it is the difference between a
    // day of recordings becoming memories and sixteen failures in a row.
    if (schemaRejected(error.status, error.message) && request.responseFormat) {
      logger.warn('The endpoint could not compile the response schema; asking for plain JSON instead', {
        purpose: request.purpose, model: settings.model, endpoint: settings.baseUrl,
        reason: String(error.message || '').slice(0, 300),
      });
      return sendChat({ ...request, responseFormat: { type: 'json_object' } }, settings.extraBody || null);
    }
    // A completion that ran out of budget on a reasoning model is the one
    // failure with an obvious second thing to try, and it matters most exactly
    // where it hurts most: consolidation treats truncation as the input's fault,
    // narrows the batch, and eventually quarantines the conversation. A model
    // that always deliberates would work through a user's whole backlog that
    // way. So rather than let it fail, ask once more without the deliberation.
    //
    // Only after a real truncation, and only if the operator has not already set
    // the field — so a provider that has no idea what it means is never sent it
    // speculatively, and if this attempt is itself rejected the original
    // truncation is what gets reported, since that is the fault worth fixing.
    if (error.code !== 'AI_OUTPUT_TRUNCATED' || thinkingAlreadyDisabled(settings.extraBody)) throw error;
    try {
      return await sendChat(request, { ...(settings.extraBody || {}), ...NO_THINKING });
    } catch (retryError) {
      throw retryError.code === 'AI_OUTPUT_TRUNCATED' ? retryError : error;
    }
  }
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
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.aiTimeoutMs);
  const startedAt = Date.now();
  try {
    const response = await fetch(`${settings.baseUrl}/chat/completions`, {
      method: 'POST', signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        ...(settings.apiKey ? { Authorization: `Bearer ${settings.apiKey}` } : {}),
      },
      body: JSON.stringify({
        model, messages, response_format: wireResponseFormat(responseFormat) || { type: 'json_object' },
        ...(maxTokens ? { max_tokens: maxTokens } : {}),
        ...(extraBody || {}),
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const detail = payload?.error?.message || `The AI endpoint returned HTTP ${response.status}.`;
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
    // Everything needed to name the cause without opening the database: which
    // endpoint, which model, what it said. This is the line that was missing
    // while an installation spent hours failing every request in silence.
    logger.warn('Language-model request failed', {
      requestId: id, purpose, model, provider: settings.provider, endpoint: settings.baseUrl,
      errorCode: code, httpStatus: error.status || null,
      seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
      reason: String(error.message || '').slice(0, 400),
    });
    error.code = code;
    error.aiRequestId = id;
    throw error;
  } finally { clearTimeout(timer); }
}

module.exports = { chatJSON, ready, contextOverflow, schemaRejected, wireSchema, wireResponseFormat, NO_THINKING };
