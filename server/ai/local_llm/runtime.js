'use strict';

const { ManagedProcess, failure } = require('../../local_runtime/managed_process');

const HEALTH_POLL_MS = 500;
const HEALTH_TIMEOUT_MS = 3_000;
// Waking an unloaded model makes /health briefly unhealthy, so one failed probe
// proves nothing; a worker is replaced only after several in a row.
const HEALTH_FAILURES_BEFORE_REPLACE = 3;

// The environment the server is given: its own search path and nothing else, so
// this process's provider keys and database key stay out of it.
function serverEnvironment() {
  const environment = {};
  for (const name of ['PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'DYLD_LIBRARY_PATH', 'LD_LIBRARY_PATH']) if (process.env[name]) environment[name] = process.env[name];
  return environment;
}

// llama.cpp's `llama-server`, kept running on loopback.
//
// It speaks the OpenAI chat-completions protocol, which is what the language-model
// provider already speaks, so nothing above this class knows the model is local.
// Process lifecycle comes from ManagedProcess. What is specific here:
//
//  * Readiness is the server answering /health, not a line it prints.
//  * The context is fixed to what the model can actually hold, and a single slot
//    is used so that context is not divided between requests.
//  * Idle unloading is the server's own (`--sleep-idle-seconds`): the process
//    stays up, drops the model from memory after the idle period, and loads it
//    again when the next request arrives. Doing it there rather than by stopping
//    this process means the HTTP and worker processes can both use the model
//    without either having to know whether the other is mid-request.
class LlamaRuntime extends ManagedProcess {
  constructor({ files, config, port, apiKey, contextSize, alias, idleSeconds, autoRestart = true, spawnImpl }) {
    const args = [
      '--model', files.weights,
      '--alias', alias,
      '--host', '127.0.0.1',
      '--port', String(port),
      '--ctx-size', String(contextSize),
      '--parallel', '1',
      '--api-key', apiKey,
      '--no-webui',
    ];
    if (idleSeconds > 0) args.push('--sleep-idle-seconds', String(idleSeconds));
    super({
      name: 'local-llm', config, autoRestart, spawnImpl, quietStderr: true,
      command: files.server, args, env: serverEnvironment(),
      startTimeoutMs: config.localLlmStartTimeoutMs,
      restartBaseMs: config.localRestartBaseMs, restartMaxMs: config.localRestartMaxMs,
    });
    this.port = port;
    this.failedHealthChecks = 0;
  }

  get healthUrl() { return `http://127.0.0.1:${this.port}/health`; }

  async #healthy() {
    try {
      const response = await fetch(this.healthUrl, { signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS) });
      return response.ok;
    } catch {
      return false;
    }
  }

  // Whether something already answers on this port that this process did not
  // start — a server left running by a worker that was killed rather than asked
  // to stop. Starting a second one would only fail to bind, so it is used as is.
  async adoptable() {
    return this.state !== 'starting' && this.state !== 'ready' && this.#healthy();
  }

  attach(child) {
    // Nothing is read from stdout, but an unread pipe would eventually block it.
    child.stdout.resume();
    const poll = setInterval(async () => {
      if (await this.#healthy()) this.markReady();
    }, HEALTH_POLL_MS);
    child.once('exit', () => clearInterval(poll));
  }

  detached() { this.failedHealthChecks = 0; }

  // Replaces a server that is alive but has stopped answering. Only a run of
  // failures counts: see HEALTH_FAILURES_BEFORE_REPLACE.
  async healthCheck() {
    if (!this.isReady()) return;
    if (await this.#healthy()) { this.failedHealthChecks = 0; return; }
    this.failedHealthChecks += 1;
    this.logger.warn('The local language model failed a health check', { consecutive: this.failedHealthChecks });
    if (this.failedHealthChecks >= HEALTH_FAILURES_BEFORE_REPLACE) { this.failedHealthChecks = 0; this.kill(); }
  }

  // Waits until the server answers, which is also how a request waits out a model
  // that is loading or being woken. Bounded by the start timeout.
  async waitUntilServing(timeoutMs = this.startTimeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (await this.#healthy()) return;
      if (Date.now() >= deadline) {
        throw failure('LOCAL_LLM_UNAVAILABLE', this.lastError?.message || 'The local language model is not answering.', { retryable: true });
      }
      await new Promise((resolve) => setTimeout(resolve, HEALTH_POLL_MS));
    }
  }
}

module.exports = { LlamaRuntime, serverEnvironment };
