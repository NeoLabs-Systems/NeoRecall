'use strict';

// Updating from the admin UI. Checking is cheap and runs here; the update
// itself is the CLI's `cmdUpdate`, run by a detached runner so it can restart
// this server.

const fs = require('node:fs');
const path = require('node:path');
const { execFile, spawn, spawnSync } = require('node:child_process');
const { APP_DIR, LOG_DIR, ensureRuntimeDirs } = require('../../../runtime/paths');
const { detectContainer } = require('../../../runtime/container');
const {
  compareVersions,
  getReleaseChannelLabel,
  parseReleaseChannel,
  readConfiguredReleaseChannel,
  writeReleaseChannelToEnvFile,
} = require('../../../runtime/release_channel');
const { checkForUpdate } = require('../../../runtime/update_check');
const { HttpError } = require('../../middleware/error_handler');
const { readUpdateStatus, writeUpdateStatus } = require('../../utils/update_status');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('updates');
const FETCH_TIMEOUT_MS = 20_000;
const CHECK_INTERVAL_MS = 6 * 60 * 60_000;
const RUNNER = path.join(APP_DIR, 'lib', 'cli', 'update_runner.js');

let lastCheck = { checkedAt: null, checked: false, update: null, reason: null, channel: null };

const run = (cmd, args, options = {}) => spawnSync(cmd, args, {
  cwd: APP_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options,
});

// package.json is read from disk: an update replaces it under a running server.
function installedVersion() {
  try {
    return JSON.parse(fs.readFileSync(path.join(APP_DIR, 'package.json'), 'utf8')).version || null;
  } catch {
    return null;
  }
}

// Why this install cannot update itself, or null when it can.
function blockedReason() {
  if (detectContainer()) return 'container';
  if (!fs.existsSync(path.join(APP_DIR, '.git'))) return 'not_git';
  return null;
}

const fetchRemote = () => new Promise((resolve) => {
  execFile('git', ['fetch', 'origin', '--tags', '--force', '--quiet'], { cwd: APP_DIR, timeout: FETCH_TIMEOUT_MS }, (error) => resolve(!error));
});

async function check() {
  const channel = readConfiguredReleaseChannel();
  if (blockedReason()) return status();
  const result = await checkForUpdate({ run, channel, fetchRemote, onFallback: (message) => logger.warn(message) });
  // A failed check keeps the last good answer: offline must not hide a banner.
  if (result.checked || !lastCheck.checked || lastCheck.channel !== channel) {
    lastCheck = { ...result, channel, checkedAt: new Date().toISOString() };
  }
  return status();
}

function status() {
  const channel = readConfiguredReleaseChannel();
  const job = readUpdateStatus();
  const version = installedVersion();
  // A check for another channel says nothing about this one.
  const known = lastCheck.channel === channel ? lastCheck : { checked: false, update: null };
  const update = known.update && compareVersions(known.update.version, version) !== 0 ? known.update : null;
  return {
    version,
    channel,
    channelLabel: getReleaseChannelLabel(channel),
    selfUpdate: blockedReason() === null,
    blockedReason: blockedReason(),
    checkedAt: known.checkedAt || null,
    checkFailed: Boolean(known.checkedAt) && known.checked === false,
    available: update,
    job: {
      state: job.state,
      phase: job.phase,
      progress: job.progress,
      message: job.message,
      versionBefore: job.versionBefore,
      versionAfter: job.versionAfter,
      changelog: job.changelog,
      rolledBack: Boolean(job.rolledBack),
      logs: job.logs,
      startedAt: job.startedAt,
      completedAt: job.completedAt,
    },
  };
}

function assertIdle() {
  const reason = blockedReason();
  if (reason === 'container') {
    throw new HttpError(409, 'UPDATE_CONTAINER', 'NeoRecall runs from a container image. Pull the new image and recreate the container.');
  }
  if (reason) throw new HttpError(409, 'UPDATE_NOT_GIT', 'This install did not come from Git, so it cannot update itself.');
  if (readUpdateStatus().state === 'running') {
    throw new HttpError(409, 'UPDATE_RUNNING', 'An update is already running.');
  }
}

function start() {
  assertIdle();
  ensureRuntimeDirs();
  writeUpdateStatus({
    state: 'running', progress: 1, phase: 'starting', message: 'Starting the update',
    startedAt: new Date().toISOString(), completedAt: null, versionBefore: installedVersion(),
    versionAfter: lastCheck.update?.version || null, rolledBack: false,
    changelog: lastCheck.update?.changes || [], logs: [], runnerPid: process.pid,
  });
  const output = fs.openSync(path.join(LOG_DIR, 'update.log'), 'a', 0o600);
  try {
    // A detached process still belongs to the service's systemd cgroup, and
    // stopping the service for the update would stop the updater with it.
    const inSystemd = process.platform === 'linux' && Boolean(process.env.INVOCATION_ID);
    const child = spawn(
      inSystemd ? 'systemd-run' : process.execPath,
      inSystemd ? ['--user', '--scope', '--quiet', '--collect', process.execPath, RUNNER] : [RUNNER],
      { cwd: APP_DIR, detached: true, stdio: ['ignore', output, output] },
    );
    child.once('error', (error) => {
      logger.error('The update runner could not start', { error: error.message });
      writeUpdateStatus({ state: 'failed', phase: 'failed', message: `The update could not start: ${error.message}`, runnerPid: null, completedAt: new Date().toISOString() });
    });
    child.once('spawn', () => writeUpdateStatus({ runnerPid: child.pid }));
    child.unref();
  } finally {
    fs.closeSync(output);
  }
  logger.info('Update started');
  return status();
}

function setChannel(requested) {
  assertIdle();
  const channel = parseReleaseChannel(requested);
  if (!channel) throw new HttpError(400, 'INVALID_CHANNEL', 'The release channel must be "stable" or "beta".');
  writeReleaseChannelToEnvFile(channel);
  process.env.NEORECALL_RELEASE_CHANNEL = channel;
  return check();
}

module.exports = { CHECK_INTERVAL_MS, check, setChannel, start, status };
