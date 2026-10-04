'use strict';

const readline = require('node:readline');
const { ManagedProcess, failure } = require('../../local_runtime/managed_process');

const PING_TIMEOUT_MS = 5_000;

// The worker is given what it needs and nothing else. It never sees this
// server's environment, which holds provider API keys and the database key.
function workerEnvironment() {
  const environment = { PYTHONNOUSERSITE: '1', PYTHONDONTWRITEBYTECODE: '1', PYTHONUTF8: '1', NEEDLE_TELEMETRY: '0', DO_NOT_TRACK: '1' };
  for (const name of ['PATH', 'LANG', 'LC_ALL', 'TMPDIR']) if (process.env[name]) environment[name] = process.env[name];
  return environment;
}

// One long-lived Whistle worker (server/transcription/local_asr/whistle_worker.py).
//
// The model loads once and then answers in milliseconds, so the worker stays
// resident rather than starting per request — it is 17 MB, and loading it for
// every thirty-second chunk of an always-on recorder would cost more than
// holding it. Process lifecycle comes from ManagedProcess; this adds the request
// protocol: JSON lines, one request at a time, because the engine holds a single
// model and is not thread-safe, and a request that does not answer in time gets
// its worker replaced rather than awaited.
class WhistleRuntime extends ManagedProcess {
  constructor({ files, config, autoRestart = true, spawnImpl }) {
    super({
      name: 'local-asr', config, autoRestart, spawnImpl,
      command: files.python, args: [files.worker, files.library, files.weights], env: workerEnvironment(),
      startTimeoutMs: config.localAsrStartTimeoutMs,
      restartBaseMs: config.localRestartBaseMs, restartMaxMs: config.localRestartMaxMs,
    });
    this.pending = new Map();
    this.sequence = 0;
    this.queue = Promise.resolve();
    this.inFlight = 0;
  }

  attach(child) {
    const lines = readline.createInterface({ input: child.stdout });
    lines.on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { this.logger.warn('Ignored a malformed line from the speech worker'); return; }
      if (message.event === 'ready') this.markReady();
      else if (message.event === 'fatal') this.markFatal(failure('LOCAL_ASR_LOAD_FAILED', String(message.error || 'The speech worker could not load the model.')));
      else this.#answer(message);
    });
    child.once('exit', () => lines.close());
  }

  detached() {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(failure('LOCAL_ASR_WORKER_EXITED', 'The speech worker stopped while a request was running.'));
    }
    this.pending.clear();
  }

  requestShutdown(child) {
    try { child.stdin.write(`${JSON.stringify({ id: 0, op: 'shutdown' })}\n`); } catch { child.kill('SIGTERM'); }
  }

  #answer(message) {
    const entry = this.pending.get(message.id);
    if (!entry) return;
    this.pending.delete(message.id);
    clearTimeout(entry.timer);
    if (message.ok) entry.resolve(message.result);
    else entry.reject(failure('LOCAL_ASR_REQUEST_FAILED', String(message.error || 'The speech engine rejected the request.')));
  }

  #send(operation, payload, timeoutMs) {
    return new Promise((resolve, reject) => {
      const child = this.child;
      if (!this.isReady() || !child) {
        reject(failure('LOCAL_ASR_UNAVAILABLE', 'Local speech recognition is not running.', { retryable: true }));
        return;
      }
      this.sequence += 1;
      const id = this.sequence;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(failure('LOCAL_ASR_TIMEOUT', `The speech worker did not answer within ${timeoutMs} ms and is being replaced.`));
        // A wedged engine cannot be asked to stop; it is replaced.
        this.kill();
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      child.stdin.write(`${JSON.stringify({ id, op: operation, ...payload })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(failure('LOCAL_ASR_UNAVAILABLE', `The speech worker could not be reached: ${error.message}`, { retryable: true }));
      });
    });
  }

  #enqueue(operation, payload, timeoutMs) {
    this.inFlight += 1;
    const run = this.queue.then(() => this.#send(operation, payload, timeoutMs));
    this.queue = run.catch(() => {}).finally(() => { this.inFlight -= 1; });
    return run;
  }

  transcribe(payload) {
    return this.#enqueue('transcribe', payload, this.config.localAsrRequestTimeoutMs);
  }

  // Cheap proof the worker is still answering. Only asks while idle, so a
  // health check never delays real work.
  async healthCheck() {
    if (!this.isReady() || this.inFlight) return;
    try {
      await this.#enqueue('ping', {}, PING_TIMEOUT_MS);
    } catch (error) {
      this.logger.warn('Local speech worker failed its health check', { reason: error.message });
    }
  }
}

// Starts a worker once and has it recognise a second of silence. Used to prove a
// freshly installed stack — interpreter, library and model together — works
// before anything is told it is installed.
async function smokeTest(files, config, spawnImpl) {
  const runtime = new WhistleRuntime({ files, config, autoRestart: false, spawnImpl });
  try {
    runtime.ensureStarted();
    await runtime.whenSettled();
    if (!runtime.isReady()) throw runtime.lastError || failure('LOCAL_ASR_LOAD_FAILED', 'The speech worker did not start.');
    const silence = Buffer.alloc(16_000 * 4).toString('base64');
    await runtime.transcribe({ samples: silence, wordTimestamps: true });
  } finally {
    await runtime.stop();
  }
}

module.exports = { WhistleRuntime, smokeTest, workerEnvironment };
