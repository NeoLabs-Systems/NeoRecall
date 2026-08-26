'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const APP_DIR = path.resolve(__dirname, '..');
const HOME_DIR = os.homedir();
const DEFAULT_RUNTIME_HOME = path.join(HOME_DIR, '.neorecall');

function expandHome(value) {
  if (!value) return DEFAULT_RUNTIME_HOME;
  if (value === '~') return HOME_DIR;
  if (value.startsWith(`~${path.sep}`)) return path.join(HOME_DIR, value.slice(2));
  return path.resolve(value);
}

function paths(env = process.env) {
  const home = expandHome(env.NEORECALL_HOME);
  return {
    home,
    data: path.join(home, 'data'),
    models: path.join(home, 'models'),
    audioTmp: path.join(home, 'audio_tmp'),
    importTmp: path.join(home, 'import_tmp'),
    context: path.join(home, 'context'),
    logs: path.join(home, 'logs'),
    backups: path.join(home, 'backups'),
    database: env.NEORECALL_DATABASE_PATH || path.join(home, 'data', 'neorecall.sqlite3'),
    envFile: path.join(home, '.env'),
    secretKey: path.join(home, 'data', 'secret.key'),
    pidFile: path.join(home, 'data', 'neorecall.pid'),
  };
}

const RUNTIME = paths();
const RUNTIME_HOME = RUNTIME.home;
const DATA_DIR = RUNTIME.data;
const LOG_DIR = RUNTIME.logs;
const ENV_FILE = RUNTIME.envFile;
const PID_FILE = RUNTIME.pidFile;
const FLUTTER_APP_DIR = path.join(APP_DIR, 'flutter_app');
const WEB_CLIENT_DIR = path.join(APP_DIR, 'flutter_app', 'build', 'web');
const LANDING_DIR = path.join(APP_DIR, 'landing');
const SERVICE_LABEL = 'systems.neolabs.neorecall';
const PLIST_DST = path.join(HOME_DIR, 'Library', 'LaunchAgents', `${SERVICE_LABEL}.plist`);
const SYSTEMD_UNIT = path.join(HOME_DIR, '.config', 'systemd', 'user', 'neorecall.service');

function ensurePrivateDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (process.platform !== 'win32') {
    try { fs.chmodSync(dir, 0o700); } catch (_) { /* best effort */ }
  }
}

function ensureRuntimeDirs(env = process.env) {
  const result = paths(env);
  for (const directory of [result.home, result.data, result.models, result.audioTmp, result.importTmp, result.context, result.logs, result.backups]) {
    ensurePrivateDirectory(directory);
  }
  return result;
}

module.exports = {
  APP_DIR,
  HOME_DIR,
  DEFAULT_RUNTIME_HOME,
  RUNTIME_HOME,
  DATA_DIR,
  LOG_DIR,
  ENV_FILE,
  PID_FILE,
  FLUTTER_APP_DIR,
  WEB_CLIENT_DIR,
  LANDING_DIR,
  SERVICE_LABEL,
  PLIST_DST,
  SYSTEMD_UNIT,
  expandHome,
  paths,
  ensureRuntimeDirs,
  ensurePrivateDirectory,
};
