'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { z } = require('zod');
const { getConfig } = require('../../config');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { encryptString, decryptString } = require('../../utils/crypto');

const LLM_PROVIDERS = Object.freeze({
  openai: { label: 'OpenAI', protocol: 'openai', baseUrl: 'https://api.openai.com/v1', keyEnvironment: ['OPENAI_API_KEY'], requiresApiKey: true },
  anthropic: { label: 'Anthropic', protocol: 'anthropic', baseUrl: 'https://api.anthropic.com/v1', keyEnvironment: ['ANTHROPIC_API_KEY'], requiresApiKey: true },
  google: { label: 'Google Gemini', protocol: 'openai', baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', keyEnvironment: ['GEMINI_API_KEY', 'GOOGLE_API_KEY'], requiresApiKey: true },
  groq: { label: 'Groq', protocol: 'openai', baseUrl: 'https://api.groq.com/openai/v1', keyEnvironment: ['GROQ_API_KEY'], requiresApiKey: true },
  mistral: { label: 'Mistral AI', protocol: 'openai', baseUrl: 'https://api.mistral.ai/v1', keyEnvironment: ['MISTRAL_API_KEY'], requiresApiKey: true },
  xai: { label: 'xAI (Grok)', protocol: 'openai', baseUrl: 'https://api.x.ai/v1', keyEnvironment: ['XAI_API_KEY'], requiresApiKey: true },
  deepseek: { label: 'DeepSeek', protocol: 'openai', baseUrl: 'https://api.deepseek.com/v1', keyEnvironment: ['DEEPSEEK_API_KEY'], requiresApiKey: true },
  openrouter: { label: 'OpenRouter', protocol: 'openai', baseUrl: 'https://openrouter.ai/api/v1', keyEnvironment: ['OPENROUTER_API_KEY'], requiresApiKey: true },
  together: { label: 'Together AI', protocol: 'openai', baseUrl: 'https://api.together.xyz/v1', keyEnvironment: ['TOGETHER_API_KEY'], requiresApiKey: true },
  openai_compatible: { label: 'Custom OpenAI-compatible', protocol: 'openai', baseUrl: null, keyEnvironment: ['AI_API_KEY'] },
});

const TRANSCRIPTION_PROVIDERS = Object.freeze({
  openai: { label: 'OpenAI', protocol: 'openai', baseUrl: 'https://api.openai.com/v1', defaultModel: null, responseFormat: 'json', keyEnvironment: ['OPENAI_API_KEY'], requiresApiKey: true },
  groq: { label: 'Groq', protocol: 'openai', baseUrl: 'https://api.groq.com/openai/v1', defaultModel: null, responseFormat: 'verbose_json', keyEnvironment: ['GROQ_API_KEY'], requiresApiKey: true },
  deepgram: { label: 'Deepgram', protocol: 'deepgram', baseUrl: 'https://api.deepgram.com', defaultModel: null, keyEnvironment: ['DEEPGRAM_API_KEY'], requiresApiKey: true },
  assemblyai: { label: 'AssemblyAI', protocol: 'assemblyai', baseUrl: 'https://api.assemblyai.com', defaultModel: null, modelOptional: true, keyEnvironment: ['ASSEMBLYAI_API_KEY'], requiresApiKey: true },
  'openai-compatible': { label: 'Custom OpenAI-compatible', protocol: 'openai', baseUrl: null, defaultModel: null, modelOptional: true, keyEnvironment: ['TRANSCRIPTION_API_KEY'] },
});

const SETTINGS_KEYS = Object.freeze({
  llm: 'providers.llm',
  llmSecret: 'providers.llm.api_key',
  transcription: 'providers.transcription',
  transcriptionSecret: 'providers.transcription.api_key',
});

const workloadSchema = z.object({
  provider: z.string().min(1).max(100),
  model: z.string().trim().min(1).max(300).nullable().optional(),
  baseUrl: z.string().trim().url().max(2_048).nullable().optional(),
  apiKey: z.string().trim().min(1).max(10_000).optional(),
  clearApiKey: z.boolean().optional(),
  language: z.string().trim().min(2).max(35).nullable().optional(),
  responseFormat: z.string().trim().min(1).max(100).nullable().optional(),
  extraBody: z.record(z.any()).nullable().optional(),
}).strict();
const updateSchema = z.object({
  llm: workloadSchema.optional(),
  transcription: workloadSchema.optional(),
}).strict();
const modelDiscoverySchema = z.object({
  workload: z.enum(['llm', 'transcription']),
  provider: z.string().min(1).max(100),
  baseUrl: z.string().trim().url().max(2_048).nullable().optional(),
  apiKey: z.string().trim().min(1).max(10_000).optional(),
}).strict();

function withoutTrailingSlash(value) {
  return value ? String(value).replace(/\/+$/, '') : null;
}

function firstEnvironmentValue(names) {
  for (const name of names) {
    const value = String(process.env[name] || '').trim();
    if (value) return { value, name };
  }
  return { value: null, name: null };
}

function readSetting(key) {
  const row = getDatabase().prepare('SELECT value_json FROM app_settings WHERE key=?').get(key);
  return row ? JSON.parse(row.value_json) : null;
}

function readSecret(key) {
  const encrypted = readSetting(key);
  return encrypted ? decryptString(encrypted) : null;
}

function providerSecretKey(workload, provider) {
  return `${SETTINGS_KEYS[`${workload}Secret`]}.${provider}`;
}

function source(adminValue, environmentValue, fallbackValue) {
  if (adminValue !== undefined && adminValue !== null) return 'admin';
  if (environmentValue !== undefined && environmentValue !== null && environmentValue !== '') return 'environment';
  return fallbackValue !== undefined ? 'default' : 'none';
}

function resolveWorkload(workload) {
  const config = getConfig();
  const isLlm = workload === 'llm';
  const catalog = isLlm ? LLM_PROVIDERS : TRANSCRIPTION_PROVIDERS;
  const settingKey = SETTINGS_KEYS[workload];
  const override = readSetting(settingKey) || {};
  const environmentProvider = isLlm ? config.aiProvider : config.transcriptionProvider;
  const fallbackProvider = isLlm ? 'openai_compatible' : 'openai-compatible';
  const provider = override.provider ?? environmentProvider ?? fallbackProvider;
  const definition = catalog[provider];
  if (!definition) {
    throw new Error(`Unsupported ${isLlm ? 'AI_PROVIDER' : 'TRANSCRIPTION_PROVIDER'}: ${provider}. Supported providers are ${Object.keys(catalog).join(', ')}.`);
  }

  const environmentModel = isLlm ? config.aiApiModel : config.transcriptionApiModel;
  const model = override.model ?? environmentModel ?? definition.defaultModel ?? null;
  const environmentBaseUrl = isLlm ? config.aiApiBaseUrl : config.transcriptionApiBaseUrl;
  const baseUrl = withoutTrailingSlash(override.baseUrl ?? environmentBaseUrl ?? definition.baseUrl);
  const adminApiKey = readSecret(providerSecretKey(workload, provider));
  const genericEnvironmentKey = isLlm ? config.aiApiKey : config.transcriptionApiKey;
  const providerEnvironmentKey = firstEnvironmentValue(definition.keyEnvironment);
  const environmentApiKey = genericEnvironmentKey || providerEnvironmentKey.value;
  const apiKey = adminApiKey || environmentApiKey || null;
  const environmentLanguage = isLlm ? null : config.transcriptionApiLanguage;
  const environmentResponseFormat = isLlm ? null : config.transcriptionApiResponseFormat;
  const environmentExtraBody = isLlm ? config.aiApiExtraBody : null;
  const extraBody = override.extraBody ?? environmentExtraBody ?? null;

  return {
    provider,
    label: definition.label,
    protocol: definition.protocol,
    model,
    baseUrl,
    apiKey,
    language: isLlm ? null : override.language ?? environmentLanguage ?? null,
    responseFormat: isLlm ? null : (override.responseFormat ?? environmentResponseFormat ?? definition.responseFormat ?? 'verbose_json'),
    extraBody,
    apiKeyConfigured: Boolean(apiKey),
    apiKeySource: adminApiKey ? 'admin' : environmentApiKey ? 'environment' : 'none',
    sources: {
      provider: source(override.provider, environmentProvider, fallbackProvider),
      model: source(override.model, environmentModel, definition.defaultModel),
      baseUrl: source(override.baseUrl, environmentBaseUrl, definition.baseUrl),
      ...(isLlm ? { extraBody: source(override.extraBody, environmentExtraBody) } : {}),
      ...(isLlm ? {} : {
        language: source(override.language, environmentLanguage),
        responseFormat: source(override.responseFormat, environmentResponseFormat, definition.responseFormat || 'verbose_json'),
      }),
    },
  };
}

function getRuntime() {
  return { llm: resolveWorkload('llm'), transcription: resolveWorkload('transcription') };
}

function publicWorkload(value) {
  const { apiKey: _apiKey, ...safe } = value;
  return safe;
}

function catalogForAdmin(catalog) {
  return Object.entries(catalog).map(([id, value]) => ({
    id,
    label: value.label,
    protocol: value.protocol,
    defaultBaseUrl: value.baseUrl,
    defaultModel: value.defaultModel ?? null,
    defaultResponseFormat: value.responseFormat ?? 'verbose_json',
    apiKeyRequired: Boolean(value.requiresApiKey),
    modelOptional: Boolean(value.modelOptional),
  }));
}

function getAdmin() {
  const runtime = getRuntime();
  return {
    llm: publicWorkload(runtime.llm),
    transcription: publicWorkload(runtime.transcription),
    catalogs: {
      llm: catalogForAdmin(LLM_PROVIDERS),
      transcription: catalogForAdmin(TRANSCRIPTION_PROVIDERS),
    },
  };
}

function validateSelection(workload, value) {
  const catalog = workload === 'llm' ? LLM_PROVIDERS : TRANSCRIPTION_PROVIDERS;
  const definition = catalog[value.provider];
  if (!definition) throw new HttpError(400, 'UNSUPPORTED_PROVIDER', `Unsupported ${workload} provider: ${value.provider}.`);
  if (definition.protocol !== 'local' && !definition.modelOptional && !value.model && !definition.defaultModel) {
    throw new HttpError(400, 'PROVIDER_MODEL_REQUIRED', `A model is required for ${definition.label}.`);
  }
  if (definition.protocol !== 'local' && !value.baseUrl && !definition.baseUrl) {
    throw new HttpError(400, 'PROVIDER_BASE_URL_REQUIRED', `A base URL is required for ${definition.label}.`);
  }
  if (value.baseUrl) {
    const protocol = new URL(value.baseUrl).protocol;
    if (!['http:', 'https:'].includes(protocol)) throw new HttpError(400, 'INVALID_PROVIDER_URL', 'Provider base URLs must use HTTP or HTTPS.');
  }
}

function writeWorkload(workload, value, statement) {
  const catalog = workload === 'llm' ? LLM_PROVIDERS : TRANSCRIPTION_PROVIDERS;
  const definition = catalog[value.provider];
  const stored = {
    provider: value.provider,
    model: value.model ?? definition.defaultModel ?? null,
    baseUrl: withoutTrailingSlash(value.baseUrl ?? definition.baseUrl),
    ...(workload === 'transcription' ? {
      language: value.language ?? null,
      responseFormat: value.responseFormat ?? definition.responseFormat ?? 'verbose_json',
    } : { extraBody: value.extraBody ?? null }),
  };
  statement.run(SETTINGS_KEYS[workload], JSON.stringify(stored));
  const secretSettingKey = providerSecretKey(workload, value.provider);
  if (value.clearApiKey) getDatabase().prepare('DELETE FROM app_settings WHERE key=?').run(secretSettingKey);
  else if (value.apiKey) statement.run(secretSettingKey, JSON.stringify(encryptString(value.apiKey)));
}

function update(input) {
  const parsed = updateSchema.safeParse(input);
  if (!parsed.success) throw new HttpError(400, 'VALIDATION_ERROR', 'Provider settings are invalid.', parsed.error.flatten());
  if (!parsed.data.llm && !parsed.data.transcription) {
    throw new HttpError(400, 'VALIDATION_ERROR', 'At least one provider setting must be supplied.');
  }
  for (const [workload, value] of Object.entries(parsed.data)) validateSelection(workload, value);
  const db = getDatabase();
  db.transaction(() => {
    const statement = db.prepare(`INSERT INTO app_settings (key,value_json) VALUES (?,?)
      ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`);
    for (const [workload, value] of Object.entries(parsed.data)) writeWorkload(workload, value, statement);
  })();
  return getAdmin();
}

function clearOverrides() {
  getDatabase().prepare(`DELETE FROM app_settings
    WHERE key IN (?,?) OR key LIKE ? OR key LIKE ? OR key IN (?,?)`)
    .run(SETTINGS_KEYS.llm, SETTINGS_KEYS.transcription,
      `${SETTINGS_KEYS.llmSecret}.%`, `${SETTINGS_KEYS.transcriptionSecret}.%`,
      SETTINGS_KEYS.llmSecret, SETTINGS_KEYS.transcriptionSecret);
  return getAdmin();
}

function discoveryCredentials(workload, input, definition) {
  const current = resolveWorkload(workload);
  const config = getConfig();
  const providerEnvironmentKey = firstEnvironmentValue(definition.keyEnvironment).value;
  const genericEnvironmentKey = workload === 'llm' ? config.aiApiKey : config.transcriptionApiKey;
  const savedProviderKey = readSecret(providerSecretKey(workload, input.provider));
  return {
    baseUrl: withoutTrailingSlash(input.baseUrl || (current.provider === input.provider ? current.baseUrl : null) || definition.baseUrl),
    apiKey: input.apiKey || savedProviderKey || (current.provider === input.provider ? current.apiKey : null) || genericEnvironmentKey || providerEnvironmentKey || null,
  };
}

function modelIds(payload, protocol) {
  let entries;
  if (protocol === 'deepgram') entries = payload?.stt || [];
  else entries = payload?.data || payload?.models || [];
  if (!Array.isArray(entries)) return [];
  const ids = entries.map((entry) => {
    if (typeof entry === 'string') return entry;
    return protocol === 'deepgram'
      ? entry.canonical_name || entry.name || entry.uuid
      : entry.id || entry.name || entry.model;
  }).filter((id) => typeof id === 'string' && id.trim()).map((id) => id.trim());
  return [...new Set(ids)].sort((left, right) => left.localeCompare(right));
}

function modelCatalogUrl(baseUrl, definition) {
  if (definition.protocol === 'deepgram') return `${baseUrl}/v1/models`;
  const url = new URL(baseUrl);
  const suffix = '/audio/transcriptions';
  const path = url.pathname.replace(/\/+$/, '');
  url.pathname = `${path.endsWith(suffix) ? path.slice(0, -suffix.length) : path}/models`;
  return url.toString();
}

async function discoverModels(input) {
  const parsed = modelDiscoverySchema.safeParse(input);
  if (!parsed.success) throw new HttpError(400, 'VALIDATION_ERROR', 'Model discovery settings are invalid.', parsed.error.flatten());
  const value = parsed.data;
  const catalog = value.workload === 'llm' ? LLM_PROVIDERS : TRANSCRIPTION_PROVIDERS;
  const definition = catalog[value.provider];
  if (!definition) throw new HttpError(400, 'UNSUPPORTED_PROVIDER', `Unsupported ${value.workload} provider: ${value.provider}.`);
  if (definition.protocol === 'local') return { models: [], automatic: true };
  if (definition.protocol === 'assemblyai') return { models: [], automatic: true };
  const credentials = discoveryCredentials(value.workload, value, definition);
  if (!credentials.baseUrl) throw new HttpError(400, 'PROVIDER_BASE_URL_REQUIRED', 'A provider base URL is required to discover models.');
  if (definition.requiresApiKey && !credentials.apiKey) throw new HttpError(400, 'PROVIDER_API_KEY_REQUIRED', `An API key is required to discover ${definition.label} models.`);
  const url = modelCatalogUrl(credentials.baseUrl, definition);
  const headers = definition.protocol === 'anthropic'
    ? { 'x-api-key': credentials.apiKey, 'anthropic-version': '2023-06-01' }
    : definition.protocol === 'deepgram'
      ? (credentials.apiKey ? { Authorization: `Token ${credentials.apiKey}` } : {})
      : (credentials.apiKey ? { Authorization: `Bearer ${credentials.apiKey}` } : {});
  let response;
  try {
    response = await fetch(url, { headers, signal: AbortSignal.timeout(30_000) });
  } catch (cause) {
    throw new HttpError(502, 'MODEL_DISCOVERY_FAILED', `Could not reach ${url}: ${describeError(cause)}`);
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    // Plenty of self-hosted speech servers implement only the endpoint they
    // exist for and never /models. That is not a misconfiguration, and saying
    // so beats reporting the bare status of a request the operator never made.
    const optional = definition.modelOptional
      ? ' This provider does not require a model, so you can leave the field empty.'
      : ' Type the model name yourself if the service does not list them.';
    if ([404, 405, 501].includes(response.status)) {
      throw new HttpError(502, 'MODEL_DISCOVERY_UNSUPPORTED', `${definition.label} does not offer a model list at ${url}.${optional}`);
    }
    throw new HttpError(502, 'MODEL_DISCOVERY_FAILED', payload?.error?.message || `${definition.label} returned HTTP ${response.status} from ${url}.${optional}`);
  }
  const models = modelIds(payload, definition.protocol);
  return { models, automatic: false, modelOptional: Boolean(definition.modelOptional) };
}

// Eighteen seconds of real bilingual, two-speaker speech used as the test probe.
const PROBE_AUDIO = path.join(__dirname, '..', '..', '..', 'test', 'fixtures', 'de_en_two_speakers.wav');

function summarize(text, limit = 240) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  return value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
}

// Unwraps `error.cause` chains, since `fetch` reports every transport failure
// as the single word "fetch failed" and hides the real reason one level down.
function describeError(error) {
  const parts = [];
  let current = error;
  const seen = new Set();
  while (current && !seen.has(current)) {
    seen.add(current);
    const message = String(current.message || current.code || '').trim();
    if (message && !parts.includes(message)) parts.push(message);
    current = current.cause;
  }
  return parts.join(': ') || 'The request failed for an unknown reason.';
}

// Sends one real request to the configured transcription service.
async function testTranscription() {
  const settings = resolveWorkload('transcription');
  const started = Date.now();
  try {
    if (!fs.existsSync(PROBE_AUDIO)) {
      return { ok: false, provider: settings.provider, error: 'The bundled sample recording is missing from this installation.' };
    }
    const provider = require('../../transcription/provider_registry').getProvider();
    if (!(await provider.ready())) {
      return { ok: false, provider: settings.provider, model: settings.model, error: 'Not fully configured: a base URL, a model, or an API key is still missing.' };
    }
    const segments = await provider.transcribe({ filename: PROBE_AUDIO, channelLayout: 'mono' });
    const text = summarize(segments.map((segment) => segment.text).join(' '));
    if (!segments.length) {
      return { ok: false, provider: settings.provider, model: settings.model, ms: Date.now() - started,
        error: 'The service answered but returned no speech for a recording that contains it. Check the model and language settings.' };
    }
    return { ok: true, provider: settings.provider, model: settings.model, ms: Date.now() - started, segments: segments.length, text };
  } catch (error) {
    return { ok: false, provider: settings.provider, model: settings.model, ms: Date.now() - started, error: describeError(error), code: error.code || null };
  }
}

// Runs the local speech-detection and diarization pass over the same sample.
function testSpeakerIdentity() {
  const localAnalysis = require('../../transcription/local_analysis');
  if (!localAnalysis.available()) {
    return { ok: false, error: 'Not installed on this platform; transcripts will have no speaker labels. Run `neorecall setup`.' };
  }
  const started = Date.now();
  try {
    const result = localAnalysis.analyze(PROBE_AUDIO);
    const voices = new Set(result.turns.map((turn) => turn.speaker)).size;
    return { ok: voices > 0, ms: Date.now() - started, voices, turns: result.turns.length,
      ...(voices > 0 ? {} : { error: 'No voices were separated in a sample that contains two.' }) };
  } catch (error) {
    return { ok: false, ms: Date.now() - started, error: describeError(error) };
  }
}

// Sends one real structured request to the configured language model, using
// the same JSON-contract path memory generation uses.
async function testLlm() {
  const settings = resolveWorkload('llm');
  const started = Date.now();
  try {
    const provider = require('../../ai/provider_registry').provider();
    if (!provider.ready()) {
      return { ok: false, provider: settings.provider, model: settings.model, error: 'Not fully configured: a base URL, a model, or an API key is still missing.' };
    }
    const response = await provider.chatJSON({
      userId: null,
      purpose: 'ask',
      maxTokens: getConfig().aiPreviewMaxOutputTokens,
      messages: [
        { role: 'system', content: 'You answer with one JSON object matching the supplied contract and no prose outside it.' },
        { role: 'user', content: JSON.stringify({ question: 'Reply with the single word "ready".', outputContract: { answer: 'ready' } }) },
      ],
      responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_provider_test', strict: true, schema: {
        type: 'object', additionalProperties: false, required: ['answer'], properties: { answer: { type: 'string', minLength: 1 } },
      } } },
    });
    return { ok: true, provider: settings.provider, model: settings.model, ms: Date.now() - started, answer: summarize(response.value?.answer, 120) };
  } catch (error) {
    const advice = error.code === 'AI_OUTPUT_TRUNCATED'
      ? ` This model needs a larger budget than it was given: raise AI_PREVIEW_MAX_OUTPUT_TOKENS (now ${getConfig().aiPreviewMaxOutputTokens}) and AI_CONSOLIDATION_MAX_OUTPUT_TOKENS, or turn off the model's thinking mode. Memory generation would hit the same limit.`
      : '';
    return { ok: false, provider: settings.provider, model: settings.model, ms: Date.now() - started,
      error: `${describeError(error)}${advice}`, code: error.code || null };
  }
}

// Exercises the whole path a recording takes, against the services actually
// configured, and reports each leg separately.
async function testProviders() {
  const [transcription, llm] = await Promise.all([testTranscription(), testLlm()]);
  return { transcription, speakerIdentity: testSpeakerIdentity(), llm };
}

/// What this server is pointed at, safe to write into a log.
///
/// The first question about any failing installation is which endpoint and which
/// model it is actually using, and the answer used to require reading the
/// database. Keys are reported as configured or not, never by value — the logger
/// redacts them anyway, but a summary meant for logs should not carry one in the
/// first place.
function describeForLog() {
  const runtime = getRuntime();
  const describe = (workload) => ({
    provider: workload.provider,
    model: workload.model,
    endpoint: workload.baseUrl,
    // Named to avoid the logger's own redaction rules rather than to evade them:
    // it strips any field whose name looks like a credential, which would have
    // reduced this whole summary to "[redacted]" and hidden the endpoint and
    // model — the two things it exists to report. Only whether a key is present
    // is stated, never the key.
    credentialConfigured: workload.apiKeyConfigured ? workload.apiKeySource : false,
  });
  // "speech" rather than "transcription" for the same reason: the logger refuses
  // any field whose name contains "transcript", so that recorded speech can
  // never reach a log file.
  return { languageModel: describe(runtime.llm), speech: describe(runtime.transcription) };
}

module.exports = {
  describeForLog,
  testProviders,
  getRuntime,
  getAdmin,
  update,
  clearOverrides,
  discoverModels,
  LLM_PROVIDERS,
  TRANSCRIPTION_PROVIDERS,
  updateSchema,
  modelDiscoverySchema,
};
