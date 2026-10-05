'use strict';

const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { createLogger } = require('../utils/logger');

const SHUTDOWN_GRACE_MS = 2_000;
// A process that stayed up this long was healthy, so its next crash starts the
// restart backoff over instead of continuing the climb.
const HEALTHY_UPTIME_MS = 60_000;
const STDERR_TAIL_LINES = 20;

function failure(code, message, extra = {}) {
  return Object.assign(new Error(message), { code, ...extra });
}

// A child process that is kept running.
//
// Both on-host models — speech recognition and the language model — are native
// programs that have to stay up for the server to be useful. This owns the part
// of that which does not depend on what the program says: starting it, deciding
// when it counts as ready, replacing it when it dies or wedges, backing off when
// it cannot start, and stopping it for good. Subclasses supply how readiness is
// recognised (a line it prints, an HTTP endpoint it answers) and what requests
// it takes.
//
// States: stopped -> starting -> ready -> (exit) backoff -> starting -> ...
class ManagedProcess {
  constructor({ name, config, command, args = [], env = {}, startTimeoutMs, restartBaseMs, restartMaxMs, autoRestart = true, quietStderr = false, spawnImpl = spawn }) {
    this.name = name;
    this.config = config;
    this.command = command;
    this.args = args;
    this.env = env;
    this.startTimeoutMs = startTimeoutMs;
    this.restartBaseMs = restartBaseMs;
    this.restartMaxMs = restartMaxMs;
    this.autoRestart = autoRestart;
    // A chatty program (llama.cpp logs every request) keeps only the last few
    // lines, which are attached to a failure instead of filling the log.
    this.quietStderr = quietStderr;
    this.stderrTail = [];
    this.spawnImpl = spawnImpl;
    this.logger = createLogger(name);
    this.state = 'stopped';
    this.closed = false;
    this.child = null;
    this.backoffMs = restartBaseMs;
    this.retryAt = 0;
    this.lastError = null;
    this.settled = Promise.resolve();
  }

  // Not ready from the moment it is told to die, rather than from the moment the
  // exit is noticed: a request sent in between would go to a corpse.
  isReady() { return this.state === 'ready' && !this.killing; }

  // Starts the process unless it is running or waiting out a restart delay.
  // Returns at once; `whenSettled` says when the start has succeeded or failed.
  ensureStarted() {
    if (this.closed || this.state === 'starting' || this.state === 'ready') return;
    if (this.state === 'backoff' && Date.now() < this.retryAt) return;
    this.#spawn();
  }

  whenSettled() { return this.settled; }

  // Subclass hooks. `attach` receives the new child to read its output;
  // `detached` is told the child is gone so it can fail what was waiting on it.
  attach(_child) {}
  detached(_error) {}

  // Called by a subclass when the process has shown it can serve.
  markReady() {
    if (this.state !== 'starting') return;
    clearTimeout(this.startTimer);
    this.state = 'ready';
    this.lastError = null;
    this.readyAt = Date.now();
    this.logger.info('Ready', { startupMs: Date.now() - this.startedAt });
    this.resolveSettled();
  }

  // Called by a subclass when the process reports it cannot serve. The process
  // is expected to exit; the exit is what schedules the restart.
  markFatal(error) {
    this.lastError = error;
  }

  #spawn() {
    this.state = 'starting';
    this.killing = false;
    this.startedAt = Date.now();
    this.settled = new Promise((resolve) => { this.resolveSettled = resolve; });
    let finished = false;
    let child;
    try {
      child = this.spawnImpl(this.command, this.args, { stdio: ['pipe', 'pipe', this.quietStderr ? 'pipe' : 'inherit'], env: this.env, windowsHide: true });
    } catch (error) {
      this.#exited(null, null, error);
      this.resolveSettled();
      return;
    }
    this.child = child;
    this.startTimer = setTimeout(() => {
      this.lastError = failure('LOCAL_RUNTIME_START_TIMEOUT', `${this.name} did not become ready within ${this.startTimeoutMs} ms.`);
      child.kill('SIGKILL');
    }, this.startTimeoutMs);
    this.startTimer.unref();
    const done = (code, signal, error) => {
      if (finished) return;
      finished = true;
      clearTimeout(this.startTimer);
      this.#exited(code, signal, error);
      this.resolveSettled();
    };
    child.on('error', (error) => done(null, null, error));
    child.on('exit', (code, signal) => done(code, signal));
    if (this.quietStderr) {
      this.stderrTail = [];
      readline.createInterface({ input: child.stderr }).on('line', (line) => {
        this.stderrTail.push(line);
        if (this.stderrTail.length > STDERR_TAIL_LINES) this.stderrTail.shift();
      });
    }
    this.attach(child);
  }

  #exited(code, signal, error) {
    const wasReady = this.state === 'ready';
    this.child = null;
    if (error && !this.lastError) this.lastError = failure('LOCAL_RUNTIME_SPAWN_FAILED', `${this.name} could not be started: ${error.message}`);
    // A program that dies before it was ever ready usually said why on stderr.
    if (!wasReady && !this.lastError && this.stderrTail.length) {
      this.lastError = failure('LOCAL_RUNTIME_EXITED', `${this.name} exited while starting: ${this.stderrTail.slice(-3).join(' | ').slice(0, 400)}`);
    }
    this.detached(this.lastError);
    if (this.closed || !this.autoRestart) { this.state = 'stopped'; return; }
    if (wasReady && Date.now() - (this.readyAt || this.startedAt) >= HEALTHY_UPTIME_MS) this.backoffMs = this.restartBaseMs;
    const delay = Math.min(this.backoffMs, this.restartMaxMs);
    this.backoffMs = Math.min(delay * 2, this.restartMaxMs);
    this.state = 'backoff';
    this.retryAt = Date.now() + delay;
    this.logger.warn('Stopped; restarting', { code, signal, delayMs: delay, reason: this.lastError?.message });
    // Restarts do not wait for the next readiness poll: "always running" means
    // the process comes back by itself.
    // The timer firing is itself the proof the delay has passed. Re-checking the
    // clock instead can see it a millisecond early (timers may fire slightly ahead
    // of Date.now()), decline to start, and leave nothing scheduled to try again.
    const timer = setTimeout(() => { this.retryAt = 0; this.ensureStarted(); }, delay);
    timer.unref();
  }

  // Replaces a process that is alive but not answering.
  kill() {
    this.killing = true;
    this.child?.kill('SIGKILL');
  }

  // Stops for good: no restart follows.
  async stop() {
    this.closed = true;
    clearTimeout(this.startTimer);
    const child = this.child;
    if (!child) { this.state = 'stopped'; return; }
    const exited = new Promise((resolve) => child.once('exit', resolve));
    this.requestShutdown(child);
    const timer = setTimeout(() => child.kill('SIGKILL'), SHUTDOWN_GRACE_MS);
    await exited;
    clearTimeout(timer);
    this.state = 'stopped';
  }

  // How to ask politely. The default is SIGTERM; a subclass may speak its own
  // protocol first.
  requestShutdown(child) {
    child.kill('SIGTERM');
  }
}

module.exports = { ManagedProcess, failure, HEALTHY_UPTIME_MS };
