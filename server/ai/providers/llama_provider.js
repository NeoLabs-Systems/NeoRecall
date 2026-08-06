'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { paths } = require('../../../runtime/paths');

/// The model runs inside this process through llama.cpp, so nothing about a
/// request leaves the machine and nothing about it is billed. Two consequences
/// shape everything below.
///
/// The first is that the answer is constrained rather than requested. llama.cpp
/// compiles a JSON schema into a grammar and the sampler is only ever allowed to
/// pick tokens that keep the output valid, so the whole class of failures that
/// dominated the hosted provider — prose around the JSON, a missing field, an
/// invented enum value — cannot occur. What remains is a completion that runs
/// out of budget mid-answer, which is reported as its own condition.
///
/// The second is that the resource being spent is this machine's memory and CPU.
/// Weights are loaded once and held while work keeps arriving, requests are
/// serialized so two jobs cannot each claim a GPU's worth of memory, and the
/// model is released again once the recorder goes quiet.

const PROVIDER = 'llama';

function modelPath() {
  const config = getConfig();
  return config.llmModelPath || path.join(paths().models, config.llmModelFile);
}

function modelLabel() {
  return path.basename(modelPath(), '.gguf');
}

function ready() {
  return fs.existsSync(modelPath());
}

/// Rewrites a contract expressed as JSON Schema into the subset llama.cpp can
/// turn into a grammar.
///
/// Only a few things differ, and each one is a narrowing rather than a change of
/// meaning. `anyOf` is spelled `oneOf`; our unions are disjoint by construction
/// (a value is either a string or null, either an object or null), so the two
/// mean the same thing here. `required` is implicit: llama.cpp always emits every
/// declared property, which is exactly what the strict contracts ask for.
///
/// `pattern`, numeric bounds and `maxLength` have no useful grammar form and are
/// dropped. The first two have no equivalent at all; the third does, but a
/// grammar expresses it by unrolling the rule once per permitted character, and
/// a two-thousand-character summary field makes the grammar itself too large to
/// compile. The response schema checks all three after generation, which is
/// where a violation was caught before as well.
const DROPPED_KEYWORDS = Object.freeze(['required', 'pattern', 'minimum', 'maximum', 'maxLength']);

function grammarSchema(schema) {
  if (Array.isArray(schema)) return schema.map(grammarSchema);
  if (!schema || typeof schema !== 'object') return schema;
  const output = {};
  for (const [key, value] of Object.entries(schema)) {
    if (DROPPED_KEYWORDS.includes(key)) continue;
    if (key === 'anyOf') { output.oneOf = value.map(grammarSchema); continue; }
    output[key] = grammarSchema(value);
  }
  return output;
}

let runtime = null;
let loading = null;
let queue = Promise.resolve();
let idleTimer = null;

/// Stops a pending release. Called when work arrives, so the idle timer can
/// never fire in the middle of a generation it was scheduled before.
function cancelUnload() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = null;
}

async function load() {
  const config = getConfig();
  const filename = modelPath();
  if (!fs.existsSync(filename)) {
    throw Object.assign(new Error(`The local language model is missing at ${filename}. Run \`neorecall setup\`.`), { code: 'AI_MODEL_MISSING' });
  }
  let llamaModule;
  try {
    // ESM-only, so it cannot be a static require from CommonJS. It is also an
    // optional dependency: a machine that only serves the API and forwards
    // generation elsewhere has no reason to carry a llama.cpp build.
    llamaModule = await import('node-llama-cpp');
  } catch (cause) {
    throw Object.assign(new Error(`The local model runtime is not installed: ${cause.message}`), { code: 'AI_RUNTIME_MISSING' });
  }
  const llama = await llamaModule.getLlama();
  const model = await llama.loadModel({
    modelPath: filename,
    gpuLayers: ['auto', 'max'].includes(config.llmGpuLayers) ? config.llmGpuLayers : Number(config.llmGpuLayers),
  });
  const context = await model.createContext({
    contextSize: Math.min(config.llmContextSize, model.trainContextSize),
    ...(config.llmThreads ? { threads: config.llmThreads } : {}),
  });
  return { llamaModule, llama, model, context, sequence: context.getSequence() };
}

async function instance() {
  if (runtime) return runtime;
  if (!loading) {
    loading = load().then((value) => { runtime = value; loading = null; return value; },
      (error) => { loading = null; throw error; });
  }
  return loading;
}

/// Releases the weights after a quiet stretch.
///
/// Scheduled work arrives in bursts — a scheduler tick queues every preview and
/// consolidation that came due together — so unloading between jobs would pay
/// the load cost several times a minute. Holding the model until the recorder
/// has been quiet gives the burst one load and gives an idle machine its memory
/// back.
function scheduleUnload() {
  const idleMs = getConfig().llmIdleUnloadMs;
  cancelUnload();
  if (!idleMs) return;
  idleTimer = setTimeout(() => { idleTimer = null; unload(); }, idleMs);
  idleTimer.unref?.();
}

async function unload() {
  const current = runtime;
  runtime = null;
  cancelUnload();
  if (!current) return;
  await current.context.dispose().catch(() => {});
  await current.model.dispose().catch(() => {});
}

/// Runs one generation at a time.
///
/// A context sequence holds the state of a single conversation with the model,
/// and the memory it occupies was reserved when the context was created. Letting
/// the worker start a preview while a consolidation is mid-answer would either
/// corrupt that state or require a second context the machine was never sized
/// for, so requests wait their turn.
function serialize(work) {
  const result = queue.then(work, work);
  queue = result.then(() => {}, () => {});
  return result;
}

function extractSchema(responseFormat) {
  if (responseFormat?.type !== 'json_schema') return null;
  return responseFormat.json_schema?.schema || null;
}

async function generate({ messages, responseFormat, maxTokens, timeoutMs }) {
  const config = getConfig();
  const { llamaModule, llama, model, sequence } = await instance();
  const schema = extractSchema(responseFormat);
  const grammar = schema
    ? await llama.createGrammarForJsonSchema(grammarSchema(schema))
    : await llama.getGrammarFor('json');
  const system = messages.filter((message) => message.role === 'system').map((message) => message.content).join('\n');
  const user = messages.filter((message) => message.role !== 'system').map((message) => message.content).join('\n');

  const promptTokens = model.tokenize(`${system}\n${user}`).length;
  const budget = maxTokens || config.aiPreviewMaxOutputTokens;
  // Caught before generation rather than after: a prompt that cannot fit leaves
  // no room for an answer, and llama.cpp would otherwise start discarding the
  // beginning of the transcript to make space — losing evidence silently is
  // worse than refusing, and the caller windows its input in response.
  if (promptTokens + budget > sequence.contextSize) {
    throw Object.assign(new Error(`The request needs ${promptTokens + budget} tokens of context but the model was given ${sequence.contextSize}.`), {
      code: 'AI_CONTEXT_EXCEEDED', promptTokens, contextSize: sequence.contextSize,
    });
  }

  const session = new llamaModule.LlamaChatSession({ contextSequence: sequence, systemPrompt: system, autoDisposeSequence: false });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const { responseText, stopReason } = await session.promptWithMeta(user, {
      grammar, maxTokens: budget, temperature: config.llmTemperature, signal: controller.signal,
    });
    if (stopReason === 'maxTokens') {
      throw Object.assign(new Error('The local model reached its output limit; the response is incomplete.'), {
        code: 'AI_OUTPUT_TRUNCATED', completionTokens: budget, reasoningTokens: null,
      });
    }
    return { value: grammar.parse(responseText), promptTokens, completionTokens: model.tokenize(responseText).length };
  } finally {
    clearTimeout(timer);
    session.dispose();
    // The next request starts from an empty history. Sessions here are
    // single-shot — every prompt already carries the context it needs — and
    // leaving the previous transcript in the sequence would spend the context
    // budget on material the caller did not send. Awaited, because the next
    // request in the queue must not begin against a half-cleared sequence.
    await sequence.clearHistory();
  }
}

async function chatJSON({ userId, purpose, messages, responseFormat = null, maxTokens = null }) {
  const config = getConfig();
  cancelUnload();
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const db = getDatabase();
  db.prepare(`INSERT INTO ai_requests (id,user_id,purpose,provider,model,state,reserved_at,sent_at)
    VALUES (?,?,?,?,?,'sent',?,?)`).run(id, userId, purpose, PROVIDER, modelLabel(), now, now);
  try {
    const result = await serialize(() => generate({ messages, responseFormat, maxTokens, timeoutMs: config.aiTimeoutMs }));
    db.prepare(`UPDATE ai_requests SET state='succeeded',prompt_tokens=?,completion_tokens=?,completed_at=? WHERE id=?`)
      .run(result.promptTokens, result.completionTokens, new Date().toISOString(), id);
    scheduleUnload();
    return { value: result.value, requestId: id };
  } catch (error) {
    const code = error.name === 'AbortError' ? 'AI_TIMEOUT' : error.code || 'AI_REQUEST_FAILED';
    db.prepare(`UPDATE ai_requests SET state='failed',error_code=?,completed_at=? WHERE id=?`)
      .run(code, new Date().toISOString(), id);
    error.code = code;
    error.aiRequestId = id;
    // A generation that was cut short left the sequence in an unknown state and
    // the weights may be the reason it failed; the next request reloads rather
    // than inheriting whatever remains.
    if (code === 'AI_TIMEOUT' || code === 'AI_REQUEST_FAILED') await unload();
    else scheduleUnload();
    throw error;
  }
}

module.exports = { chatJSON, ready, unload, grammarSchema, modelPath, modelLabel };
