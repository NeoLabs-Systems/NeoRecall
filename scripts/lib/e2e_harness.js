'use strict';

// Shared scaffolding for the end-to-end smoke runs: a real server process with
// the real speech models, a stubbed language-model endpoint, and the polling
// helpers both runs need. Only the scenario lives in each script.
//
// The stub speaks the OpenAI chat-completions contract and the server is pointed
// at it with AI_PROVIDER=openai_compatible, so the smoke run exercises the whole
// pipeline in seconds without loading two and a half gigabytes of weights and
// without its assertions depending on what a real model happened to write. The
// local provider is covered where its behaviour actually differs: the grammar it
// derives from each contract, and the windowing that keeps a long transcript
// inside its context.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const { spawn } = require('node:child_process');
const manifest = require('../../models/manifest.json');

const repositoryRoot = path.join(__dirname, '..', '..');

function assert(condition, message) { if (!condition) throw new Error(message); }
function progress(label, message) { process.stdout.write(`[${label}] ${message}\n`); }
function delay(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function wavParts(bytes) {
  let offset = 12; let byteRate; let dataStart; let dataSize;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4); const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ') byteRate = bytes.readUInt32LE(offset + 16);
    if (id === 'data') { dataStart = offset + 8; dataSize = size; break; }
    offset += 8 + size + (size % 2);
  }
  if (!byteRate || dataStart === undefined) throw new Error('E2E fixture is not a supported PCM WAV file.');
  return { header: bytes.subarray(0, dataStart), byteRate, dataStart, dataSize };
}

function wavDurationMs(bytes) {
  const { byteRate, dataSize } = wavParts(bytes);
  return Math.round(dataSize / byteRate * 1000);
}

/// Cuts a PCM WAV into `count` playable WAV files of roughly equal length.
///
/// The live run needs a recording that arrives in pieces the way capture
/// delivers it, and each piece has to be independently decodable because that is
/// exactly what the ingest contract promises.
function sliceWav(bytes, count) {
  const { header, byteRate, dataStart, dataSize } = wavParts(bytes);
  const frameSize = 2;
  const perSlice = Math.floor(dataSize / count / frameSize) * frameSize;
  assert(perSlice > 0, 'The fixture is too short to slice.');
  const slices = [];
  for (let index = 0; index < count; index += 1) {
    const start = dataStart + index * perSlice;
    const end = index === count - 1 ? dataStart + dataSize : start + perSlice;
    const audio = bytes.subarray(start, end);
    const sliceHeader = Buffer.from(header);
    sliceHeader.writeUInt32LE(sliceHeader.length - 8 + audio.length, 4);
    sliceHeader.writeUInt32LE(audio.length, sliceHeader.length - 4);
    slices.push({ bytes: Buffer.concat([sliceHeader, audio]), durationMs: Math.round(audio.length / byteRate * 1000) });
  }
  return slices;
}

async function api(baseUrl, method, route, token, body) {
  const response = await fetch(`${baseUrl}${route}`, {
    method,
    signal: AbortSignal.timeout(150_000),
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw Object.assign(new Error(value.error?.message || `${method} ${route} returned ${response.status}`), { status: response.status, value });
  }
  return value;
}

/// Polls until a predicate holds.
///
/// `guard` returns a reason to stop waiting altogether. Transient errors are
/// expected while a pipeline stage catches up and are retried, but a condition
/// that can never resolve — the server died — has to abort now rather than be
/// reported as a timeout many minutes later.
function pollFactory(timeoutMs, guard = null) {
  return async function poll(label, operation, predicate, deadline = Date.now() + timeoutMs) {
    let last;
    while (Date.now() < deadline) {
      const fatal = guard && guard();
      if (fatal) throw new Error(`${label} aborted: ${fatal}`);
      try { last = await operation(); if (predicate(last)) return last; } catch (error) { last = error; }
      await delay(1000);
    }
    throw new Error(`${label} timed out. Last result: ${last instanceof Error ? last.message : JSON.stringify(last)}`);
  };
}

function defaultConsolidation(input) {
  const sectionsByStream = new Map();
  for (const item of input.conversations) {
    if (!sectionsByStream.has(item.stream)) sectionsByStream.set(item.stream, []);
    sectionsByStream.get(item.stream).push(...item.segments.map((segment) => segment.id));
  }
  const sourceSegmentIds = [...sectionsByStream.values()].flat();
  const conversation = input.conversations[0];
  const segment = conversation.segments[0];
  return {
    conversationSections: [...sectionsByStream.values()].map((segmentIds) => ({
      titleEn: 'Project discussion',
      summaryEn: 'A bilingual project discussion assigned follow-up work.',
      memoryWorthy: true,
      topics: ['Project planning'],
      continuesPrevious: false,
      sourceSegmentIds: segmentIds,
    })),
    entities: [],
    memories: [{
      type: 'project_discussion', continuesPrevious: false, titleEn: 'Project discussion', summaryEn: 'A bilingual project discussion assigned follow-up work.',
      emoji: '📋', importance: 7, sourceSegmentIds, topics: ['Project planning'], entities: [],
      miniMemories: [{ kind: 'task', textEn: 'Follow up on the discussed project work.', importance: 7, confidence: 0.8,
        dueAt: null, occurredAt: null, status: 'open', sourceSegmentIds: [segment.id], entities: [] }],
    }],
    dailySummary: { localDate: conversation.recorded.localStartedAt.slice(0, 10), timezone: input.timezone, summaryEn: 'A bilingual project discussion produced follow-up work.' },
  };
}

function defaultPreview() {
  return { titleEn: 'Ongoing project discussion', summaryEn: 'The recording so far covers project work.', memoryWorthy: true, topics: ['Project planning'] };
}

function defaultAsk(input) {
  return { answer: 'The recalled discussion concerned project work and a follow-up.', citations: input.context.length ? [{ sourceId: input.context[0].sourceId }] : [] };
}

/// A stand-in model endpoint that answers each prompt kind with a valid contract
/// response and records what it was asked, so a scenario can assert on the
/// request rather than only on what was stored.
function modelEndpointMock(handlers = {}) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const system = payload.messages[0].content;
    const input = JSON.parse(payload.messages[1].content);
    const purpose = system.includes('consolidate personal transcripts') ? 'consolidation'
      : system.includes('still being recorded') ? 'preview' : 'ask';
    requests.push({ purpose, input, payload, system });
    const handler = handlers[purpose] || { consolidation: defaultConsolidation, preview: defaultPreview, ask: defaultAsk }[purpose];
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      id: `mock-${requests.length}`,
      usage: { prompt_tokens: 20, completion_tokens: 20, cost: 0 },
      choices: [{ message: { content: JSON.stringify(handler(input, payload)) } }],
    }));
  });
  return {
    server,
    requests,
    count: (purpose) => (purpose ? requests.filter((entry) => entry.purpose === purpose).length : requests.length),
    of: (purpose) => requests.filter((entry) => entry.purpose === purpose),
  };
}

function requireModels(sourceModels) {
  for (const model of manifest.models) {
    for (const file of model.files) {
      assert(fs.existsSync(path.join(sourceModels, file.path)), `Run neorecall setup first; missing ${file.path} in ${sourceModels}.`);
    }
  }
}

/// Boots a real NeoRecall server against a throwaway home directory and the
/// real model files, and returns everything the scenario needs to talk to it.
async function startServer({ label, env = {}, mockHandlers = {}, sourceModels, timeoutMs }) {
  requireModels(sourceModels);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), `neorecall-${label}-`));
  fs.symlinkSync(sourceModels, path.join(home, 'models'), 'dir');
  const port = await freePort();
  const mock = modelEndpointMock(mockHandlers);
  await new Promise((resolve) => mock.server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${port}`;
  let logs = '';
  const child = spawn(process.execPath, [path.join(repositoryRoot, 'server', 'index.js')], {
    cwd: repositoryRoot,
    env: {
      ...process.env,
      NODE_ENV: 'test',
      NEORECALL_HOME: home,
      NEORECALL_HOST: '127.0.0.1',
      NEORECALL_PORT: String(port),
      NEORECALL_REQUIRE_VECTOR: 'true',
      NEORECALL_TRANSFORMERS_LOCAL_PATH: path.join(home, 'models'),
      AI_PROVIDER: 'openai_compatible',
      AI_API_BASE_URL: `http://127.0.0.1:${mock.server.address().port}`,
      AI_API_MODEL: 'e2e/mock',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const collect = (value) => { logs = `${logs}${value}`.slice(-30_000); };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  // A server that refuses to start — bad configuration, a missing model — must
  // surface its reason immediately instead of being polled until the run's
  // timeout expires and reports a meaningless "startup timed out".
  let exited = null;
  child.on('exit', (code, signal) => { exited = { code, signal }; });
  const poll = pollFactory(timeoutMs, () => exited && `the server process exited (code ${exited.code}, signal ${exited.signal})`);
  // `keepHome` leaves the database and its transcripts behind, so a run worth
  // inspecting afterwards does not have to be repeated to be read.
  const stop = async ({ keepHome = false } = {}) => {
    child.kill('SIGTERM');
    mock.server.close();
    await delay(500);
    if (!keepHome) fs.rmSync(home, { recursive: true, force: true });
  };
  return { baseUrl, mock, poll, stop, home, logs: () => logs };
}

/// Runs a scenario and always reports the server log tail on failure, because a
/// pipeline failure is almost never explained by the assertion alone.
async function runScenario(label, options, scenario) {
  const context = await startServer({
    label,
    timeoutMs: options.timeoutMs,
    sourceModels: options.sourceModels,
    env: options.env,
    mockHandlers: options.mockHandlers,
  });
  try {
    const say = (message) => progress(label, message);
    say('waiting for HTTP and model readiness');
    await context.poll('HTTP startup', () => fetch(`${context.baseUrl}/health`), (response) => response.ok);
    await context.poll('server readiness', () => fetch(`${context.baseUrl}/ready`).then((response) => response.json()), (value) => value.status === 'ready');
    await scenario({ ...context, say, api: (method, route, token, body) => api(context.baseUrl, method, route, token, body) });
  } catch (error) {
    throw new Error(`${error.message}\nServer log tail:\n${context.logs()}`);
  } finally {
    await context.stop();
  }
}

module.exports = {
  assert, progress, delay, freePort, api, pollFactory, sliceWav, wavDurationMs, wavParts,
  modelEndpointMock, startServer, runScenario, requireModels,
  defaultConsolidation, defaultPreview, defaultAsk,
};
