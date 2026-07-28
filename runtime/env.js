'use strict';

const fs = require('node:fs');
const dotenv = require('dotenv');
const { ENV_FILE, ensureRuntimeDirs } = require('./paths');

function parseEnv(raw) {
  const map = new Map();
  for (const line of String(raw ?? '').split(/\r?\n/)) {
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const idx = line.indexOf('=');
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1);
    if (key) map.set(key, value);
  }
  return map;
}

function readEnvFileRaw(envFile = ENV_FILE) {
  try {
    return fs.readFileSync(envFile, 'utf8');
  } catch {
    return '';
  }
}

function writeEnvFileAtomic(envFile, content) {
  ensureRuntimeDirs();
  const temporary = `${envFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, content, { encoding: 'utf8', mode: 0o600 });
  fs.renameSync(temporary, envFile);
  try { fs.chmodSync(envFile, 0o600); } catch (_) { /* best effort */ }
}

function normalizeEnvKey(key) {
  const normalized = String(key).replace(/[\r\n]/g, '');
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(normalized)) {
    throw new Error(`Invalid environment variable name: ${normalized || '(empty)'}`);
  }
  return normalized;
}

function upsertEnvValue(envFile, key, value) {
  const safeKey = normalizeEnvKey(key);
  const safeValue = String(value).replace(/[\r\n]/g, '');
  const raw = readEnvFileRaw(envFile);
  const lines = raw ? raw.split('\n') : [];
  let replaced = false;
  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i].startsWith(`${safeKey}=`)) {
      lines[i] = `${safeKey}=${safeValue}`;
      replaced = true;
      break;
    }
  }
  if (!replaced) lines.push(`${safeKey}=${safeValue}`);
  const output = `${lines.filter((line, idx, arr) => idx !== arr.length - 1 || line !== '').join('\n')}\n`;
  writeEnvFileAtomic(envFile, output);
}

function removeEnvValue(envFile, key) {
  const safeKey = normalizeEnvKey(key);
  const raw = readEnvFileRaw(envFile);
  if (!raw) return false;
  const lines = raw.split('\n').filter((line) => !line.startsWith(`${safeKey}=`));
  writeEnvFileAtomic(envFile, `${lines.filter((line, idx, arr) => idx !== arr.length - 1 || line !== '').join('\n')}\n`);
  return true;
}

function loadEnvironment() {
  ensureRuntimeDirs();
  const envFile = ENV_FILE;
  if (fs.existsSync(envFile)) dotenv.config({ path: envFile, override: false });
  dotenv.config({ override: false, quiet: true });
}

module.exports = {
  parseEnv,
  readEnvFileRaw,
  writeEnvFileAtomic,
  upsertEnvValue,
  removeEnvValue,
  loadEnvironment,
  normalizeEnvKey,
};
