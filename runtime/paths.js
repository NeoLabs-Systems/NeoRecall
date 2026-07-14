'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function expandHome(value) {
  if (!value) return path.join(os.homedir(), '.neorecall');
  if (value === '~') return os.homedir();
  if (value.startsWith(`~${path.sep}`)) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

function paths() {
  const home = expandHome(process.env.NEORECALL_HOME);
  return {
    home,
    data: path.join(home, 'data'),
    models: path.join(home, 'models'),
    audioTmp: path.join(home, 'audio_tmp'),
    importTmp: path.join(home, 'import_tmp'),
    logs: path.join(home, 'logs'),
    database: process.env.NEORECALL_DATABASE_PATH || path.join(home, 'data', 'neorecall.sqlite3'),
    envFile: path.join(home, '.env'),
    secretKey: path.join(home, 'data', 'secret.key'),
  };
}

function ensureRuntimeDirs() {
  const result = paths();
  for (const directory of [result.home, result.data, result.models, result.audioTmp, result.importTmp, result.logs]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    try { fs.chmodSync(directory, 0o700); } catch (_) { /* Best effort on Windows. */ }
  }
  return result;
}

module.exports = { paths, ensureRuntimeDirs, expandHome };
