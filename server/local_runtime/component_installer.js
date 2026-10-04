'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const download = require('./download');
const manifestModule = require('./manifest');
const { readZipMember } = require('./zip_member');
const { createLogger } = require('../utils/logger');

const logger = createLogger('local-install');
const execFileAsync = promisify(execFile);

// A lock nobody has touched for this long belongs to a process that died.
const LOCK_STALE_MS = 60_000;
const LOCK_HEARTBEAT_MS = 5_000;
const PROGRESS_WRITE_MS = 500;
const ARCHIVE_MARKER = '.archive-sha256';

function installFailure(code, message) {
  return Object.assign(new Error(message), { code });
}

// Puts a local component on disk — the programs and model files a manifest entry
// lists, each downloaded at a pinned version and verified by SHA-256 — and
// proves the stack works before calling it installed.
//
// Everything here is built to be interrupted. Each artifact skips what is
// already correct, downloads resume, and nothing counts as installed until the
// component's own smoke test has passed — so a crash, a restart or a flaky
// network leaves a state the next call simply continues from. State lives in a
// file beside the files and a lock file keeps the HTTP and worker processes from
// installing at the same time; either can start an install and either can read
// how it is going.
//
// What an installed component *is* — which process it runs, what it serves —
// is not this class's business. The caller supplies `smoke`, which starts the
// component once and exercises it.
class ComponentInstaller {
  constructor({ manifest, componentId, directory, platform = manifestModule.platformKey(), config, fetchImpl = fetch, smoke }) {
    this.entry = manifestModule.component(manifest, componentId);
    this.platformKey = platform;
    this.platform = this.entry.platforms?.[platform] || null;
    this.directory = directory;
    this.config = config;
    this.fetchImpl = fetchImpl;
    this.smoke = smoke;
    this.statePath = path.join(directory, 'state.json');
    this.lockPath = path.join(directory, 'install.lock');
    this.active = null;
    this.bytesDone = 0;
    this.lastProgressWrite = 0;
  }

  get supported() { return Boolean(this.platform); }

  artifacts() { return manifestModule.artifactsFor(this.entry, this.platform); }

  languages() { return this.entry.languages || []; }

  // The absolute path an installed artifact is used from.
  pathOf(id) {
    const artifact = this.artifacts().find((candidate) => candidate.id === id);
    if (!artifact) throw new Error(`${this.entry.id} has no artifact ${id}.`);
    return path.join(this.directory, artifact.type === 'tar-archive' ? artifact.check : artifact.path);
  }

  #readState() {
    try { return JSON.parse(fs.readFileSync(this.statePath, 'utf8')); } catch { return {}; }
  }

  #writeState(patch) {
    const next = { ...this.#readState(), ...patch, updatedAt: new Date().toISOString() };
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const temporary = `${this.statePath}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(next), { mode: 0o600 });
    fs.renameSync(temporary, this.statePath);
  }

  #lockIsFresh() {
    try { return Date.now() - fs.statSync(this.lockPath).mtimeMs < LOCK_STALE_MS; } catch { return false; }
  }

  // Cheap enough to ask on every readiness poll: a `stat` per artifact and one
  // small file. The expensive proof — hashing and loading — happened when the
  // install finished, and is tied to the manifest by the fingerprint.
  isInstalled() {
    if (!this.supported) return false;
    if (this.#readState().verifiedFingerprint !== manifestModule.fingerprint(this.entry, this.platform)) return false;
    return this.artifacts().every((artifact) => {
      try {
        const stat = fs.statSync(this.pathOf(artifact.id));
        if (artifact.type === 'file') return stat.size === artifact.size;
        if (artifact.type === 'zip-member') return stat.size === artifact.fileSize;
        return true;
      } catch { return false; }
    });
  }

  status() {
    const base = {
      id: this.entry.id, kind: this.entry.kind, label: this.entry.label,
      license: this.entry.license, licenseUrl: this.entry.licenseUrl || null,
      languages: this.entry.languages || [], platform: this.platformKey, supported: this.supported,
    };
    if (!this.supported) {
      return { ...base, phase: 'unsupported', reason: `${this.entry.label} is not available for ${this.platformKey}.`, progress: null, error: null, downloadBytes: 0 };
    }
    const state = this.#readState();
    const installed = this.isInstalled();
    // `installing` in the state file only counts while something still holds the
    // lock; otherwise the process that was installing is gone.
    const installing = !installed && (Boolean(this.active) || this.#lockIsFresh());
    let phase = 'not_installed';
    if (installed) phase = 'installed';
    else if (installing) phase = 'installing';
    else if (state.phase === 'failed') phase = 'failed';
    return {
      ...base,
      phase,
      downloadBytes: manifestModule.downloadBytes(this.entry, this.platform),
      progress: installing && state.progress ? state.progress : null,
      error: phase === 'failed' ? state.error || null : null,
    };
  }

  // Starts an installation unless one is already running or the last one failed
  // too recently to try again. Always resolves, to the status afterwards:
  // failures are recorded in the state rather than thrown, so a caller that does
  // not wait for it cannot produce an unhandled rejection.
  ensureInstalled({ force = false } = {}) {
    if (!this.supported || this.isInstalled()) return Promise.resolve(this.status());
    if (this.active) return this.active;
    const state = this.#readState();
    if (!force && state.phase === 'failed' && Date.now() - (state.failedAt || 0) < this.config.localInstallRetryMs) {
      return Promise.resolve(this.status());
    }
    if (!this.#acquireLock()) return Promise.resolve(this.status());
    // The status is read after `active` is cleared, or a failed install would
    // still report itself as running.
    const running = this.#run().finally(() => { this.active = null; }).then(() => this.status());
    this.active = running;
    return running;
  }

  #acquireLock() {
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        fs.closeSync(fs.openSync(this.lockPath, 'wx', 0o600));
        return true;
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        if (this.#lockIsFresh()) return false;
        fs.rmSync(this.lockPath, { force: true });
      }
    }
    return false;
  }

  async #run() {
    const heartbeat = setInterval(() => { try { fs.utimesSync(this.lockPath, new Date(), new Date()); } catch { /* lock removed */ } }, LOCK_HEARTBEAT_MS);
    heartbeat.unref();
    this.bytesDone = 0;
    const total = manifestModule.downloadBytes(this.entry, this.platform);
    try {
      this.#writeState({ phase: 'installing', error: null, progress: { step: this.artifacts()[0].id, percent: 0 } });
      logger.info('Installing a local component', { component: this.entry.id, platform: this.platformKey, bytes: total });
      for (const artifact of this.artifacts()) {
        await this.#install(artifact);
        this.bytesDone += artifact.size;
      }
      this.#writeState({ progress: { step: 'verify', percent: 100 } });
      await this.smoke(this);
      this.#writeState({ phase: 'installed', progress: null, error: null, failedAt: null, verifiedFingerprint: manifestModule.fingerprint(this.entry, this.platform) });
      fs.rmSync(path.join(this.directory, '.downloads'), { recursive: true, force: true });
      logger.info('A local component is installed', { component: this.entry.id });
    } catch (error) {
      logger.error('Installing a local component failed', { component: this.entry.id, errorCode: error.code || 'LOCAL_INSTALL_FAILED', reason: error.message });
      this.#writeState({
        phase: 'failed', progress: null, failedAt: Date.now(), verifiedFingerprint: null,
        error: { code: error.code || 'LOCAL_INSTALL_FAILED', message: String(error.message).slice(0, 500) },
      });
    } finally {
      clearInterval(heartbeat);
      fs.rmSync(this.lockPath, { force: true });
    }
  }

  #install(artifact) {
    if (artifact.type === 'file') return this.#installFile(artifact);
    if (artifact.type === 'tar-archive') return this.#installTar(artifact);
    return this.#installZipMember(artifact);
  }

  #downloadOptions(artifact) {
    return {
      attempts: this.config.localDownloadAttempts,
      idleTimeoutMs: this.config.localDownloadIdleTimeoutMs,
      fetchImpl: this.fetchImpl,
      onProgress: (received) => this.#progress(artifact.id, this.bytesDone + received),
    };
  }

  // Progress is one overall figure across every download, so the number never
  // jumps backwards when a small artifact follows a large one. Written to disk
  // at most twice a second: another process reads it, and it is not a log.
  #progress(step, doneBytes) {
    const now = Date.now();
    if (now - this.lastProgressWrite < PROGRESS_WRITE_MS) return;
    this.lastProgressWrite = now;
    const total = manifestModule.downloadBytes(this.entry, this.platform);
    this.#writeState({ progress: { step, percent: Math.min(99, Math.floor((doneBytes / total) * 100)) } });
  }

  async #installFile(artifact) {
    await download.downloadVerified(artifact, path.join(this.directory, artifact.path), this.#downloadOptions(artifact));
  }

  #fetchArchive(artifact) {
    const archivePath = path.join(this.directory, '.downloads', artifact.filename);
    return download.downloadVerified(artifact, archivePath, this.#downloadOptions(artifact)).then(() => archivePath);
  }

  // The archive is unpacked beside its destination and renamed into place, so an
  // interrupted extraction never leaves a half-written program where a good one
  // was.
  async #installTar(artifact) {
    const root = path.join(this.directory, artifact.extractTo);
    const marker = path.join(root, ARCHIVE_MARKER);
    const markerValue = () => { try { return fs.readFileSync(marker, 'utf8').trim(); } catch { return null; } };
    if (fs.existsSync(path.join(this.directory, artifact.check)) && markerValue() === artifact.sha256) return;
    const archivePath = await this.#fetchArchive(artifact);
    const staging = path.join(this.directory, `.extract-${artifact.id}-${process.pid}`);
    fs.rmSync(staging, { recursive: true, force: true });
    fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
    try {
      const flag = /\.(tar\.bz2|tbz2?)$/.test(artifact.filename) ? '-xjf' : '-xzf';
      const args = [flag, archivePath, '-C', staging];
      if (artifact.stripComponents) args.push(`--strip-components=${artifact.stripComponents}`);
      try {
        await execFileAsync('tar', args, { maxBuffer: 1 << 20 });
      } catch (error) {
        throw installFailure('LOCAL_ARCHIVE_INVALID', `Could not unpack ${artifact.filename}: ${error.stderr || error.message}`);
      }
      if (!fs.existsSync(path.join(staging, path.relative(artifact.extractTo, artifact.check)))) {
        throw installFailure('LOCAL_ARCHIVE_INVALID', `${artifact.filename} does not contain ${artifact.check}.`);
      }
      fs.writeFileSync(path.join(staging, ARCHIVE_MARKER), artifact.sha256);
      fs.rmSync(root, { recursive: true, force: true });
      fs.renameSync(staging, root);
    } finally {
      fs.rmSync(staging, { recursive: true, force: true });
    }
  }

  async #installZipMember(artifact) {
    const destination = path.join(this.directory, artifact.path);
    if (await download.matches(destination, { size: artifact.fileSize, sha256: artifact.fileSha256 })) return;
    const archivePath = await this.#fetchArchive(artifact);
    const data = readZipMember(fs.readFileSync(archivePath), artifact.member);
    if (crypto.createHash('sha256').update(data).digest('hex') !== artifact.fileSha256) {
      throw installFailure('LOCAL_CHECKSUM_MISMATCH', `SHA-256 verification failed for ${artifact.member}.`);
    }
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    const installing = `${destination}.installing`;
    fs.writeFileSync(installing, data, { mode: 0o755 });
    fs.renameSync(installing, destination);
  }
}

module.exports = { ComponentInstaller };
