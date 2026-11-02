'use strict';

const net = require('node:net');
const path = require('node:path');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { getConfig } = require('../../config');
const manifestModule = require('../../local_runtime/manifest');
const { ComponentInstaller } = require('../../local_runtime/component_installer');
const { LlamaRuntime } = require('./runtime');
const endpoint = require('./endpoint');

const COMPONENT_ID = 'gemma-2-2b-it';

let installer;
let runtime;
// Set by the process that keeps the server running (the worker). Other
// processes use the server but never start it.
let keeper = false;

function filesOf(component) {
  return { server: component.pathOf('server'), weights: component.pathOf('weights') };
}

function alias() { return COMPONENT_ID; }

function newRuntime(component, overrides = {}) {
  const config = getConfig();
  return new LlamaRuntime({
    files: filesOf(component), config, alias: alias(),
    port: config.localLlmPort, apiKey: endpoint.apiKey(),
    contextSize: component.entry.profile.contextSize, idleSeconds: config.localLlmIdleUnloadSeconds,
    ...overrides,
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
}

// Proves an installed stack works: starts the server on a spare port, has it
// answer a real chat request, stops it. A separate instance on its own port, so
// installing never disturbs a server that is already serving.
async function smokeTest(component) {
  const config = getConfig();
  const key = endpoint.apiKey();
  const port = await freePort();
  const probe = newRuntime(component, { port, idleSeconds: 0, autoRestart: false });
  try {
    probe.ensureStarted();
    await probe.whenSettled();
    if (!probe.isReady()) throw probe.lastError;
    const response = await fetch(`http://127.0.0.1:${port}/v1/chat/completions`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: alias(), max_tokens: 8, messages: [{ role: 'user', content: 'Reply with the word ready.' }] }),
      signal: AbortSignal.timeout(config.localLlmStartTimeoutMs),
    });
    if (!response.ok) throw Object.assign(new Error(`The local language model answered HTTP ${response.status}.`), { code: 'LOCAL_LLM_SMOKE_FAILED' });
    const payload = await response.json();
    if (!payload?.choices?.[0]?.message) throw Object.assign(new Error('The local language model returned no message.'), { code: 'LOCAL_LLM_SMOKE_FAILED' });
  } finally {
    await probe.stop();
  }
}

function getInstaller() {
  if (!installer) {
    installer = new ComponentInstaller({
      manifest: manifestModule.load(),
      componentId: COMPONENT_ID,
      directory: path.join(ensureRuntimeDirs().models, 'local', COMPONENT_ID),
      config: getConfig(),
      smoke: smokeTest,
    });
  }
  return installer;
}

function getRuntime() {
  if (!runtime) runtime = newRuntime(getInstaller());
  return runtime;
}

// Called repeatedly by the one process that owns the server. Brings the world
// into line with the configuration: installs when selected and missing, starts
// when installed, replaces when wedged, and stops when the operator switches to
// another provider.
async function maintain({ selected }) {
  keeper = true;
  if (!selected) {
    if (runtime) { await runtime.stop(); runtime = undefined; }
    return;
  }
  const component = getInstaller();
  if (!component.supported) return;
  if (!component.isInstalled()) { component.ensureInstalled(); return; }
  const server = getRuntime();
  if (await server.adoptable()) return;
  server.ensureStarted();
  await server.healthCheck();
}

// Resolves once the server answers, starting it first in the process that owns
// it. A request that arrives while the model is loading or being woken waits
// here rather than failing.
async function ensureServing() {
  const component = getInstaller();
  if (!component.supported || !component.isInstalled()) {
    throw Object.assign(new Error(`${component.entry.label} is not installed yet.`), { code: 'LOCAL_LLM_UNAVAILABLE', retryable: true });
  }
  const server = getRuntime();
  if (keeper) server.ensureStarted();
  await server.waitUntilServing();
}

async function reset() {
  await runtime?.stop();
  runtime = undefined;
  installer = undefined;
  keeper = false;
}

module.exports = { getInstaller, getRuntime, maintain, ensureServing, reset, endpoint, COMPONENT_ID };
